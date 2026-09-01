// cellar-daemon —— root LaunchDaemon 入口（WP6）。
//
// 装配顺序（规格 §3）：
//   1. 单一属主 DaemonCore（策略/控制器/backend 唯一归属）
//   2. startup：载入（校验式）策略 → 探测 → active 则 enforce（启动即校对）
//   3. raw XPC 监听（⚠️ 非 launchd 手动直跑/监听失败 → fatal 退出，防双写者野进程）
//   4. 信号：先 signal(SIG, SIG_IGN) 再建 DispatchSourceSignal（评审 C-4）；
//      SIGTERM/SIGINT → restoreAndExit；SIGHUP → 重读 policy（不退出）
//   5. 30 秒心跳（主 RunLoop CFRunLoopTimer）
//   6. 电源通知（IORegisterForSystemPower + 主 RunLoop source；逐消息 ack 纪律，评审 D-1）
//   7. CFRunLoopRun()
//
// 本文件是纯装配：全部状态操作经 DaemonCore 加锁方法，os_log 在锁外（生命周期日志在此层）。

import Foundation
import IOKit
import IOKit.pwr_mgt
import Darwin
import os
import CellarCore

// MARK: - 全局桥（C 回调/信号处理器经此访问单一属主）

/// 非隔离全局：仅在主线程装配后由 C 回调/定时器读取；DaemonCore 内部有锁，读取本身无数据竞争面。
nonisolated(unsafe) private var daemonCore: DaemonCore?

/// 系统电源根端口（IORegisterForSystemPower 返回；⚠️ 强引用防释放——释放后电源回调全部失效）。
nonisolated(unsafe) private var powerRootPort: io_connect_t = 0

/// 信号源强引用（DispatchSourceSignal 释放即失效）。
nonisolated(unsafe) private var signalSources: [DispatchSourceSignal] = []

/// 跨进程互斥锁 fd（防线 b）：进程生命周期全局持有，从不关闭——文件锁随进程退出自动释放。
nonisolated(unsafe) private var daemonLockFD: Int32 = -1

private let lifecycleLog = Logger(subsystem: "com.cellar.daemon", category: "lifecycle")

// MARK: - 入口

// 0. 跨进程互斥（防线 b，第一条可执行逻辑）：双路线（App 托管 / CLI 手工）可注册同一
// Label——launchd 对同 Label 碰撞的行为未经隔离实证，flock 是进程级兜底：另一路线的
// daemon 存活即拿不到锁。失败 → fault + 非零退出；配合 KeepAlive 与 launchd 默认
// ThrottleInterval=10s，最坏每 10s 一次快速失败——另一方死后本进程在下一节流窗接管。
if !acquireDaemonLock() {
    lifecycleLog.fault("互斥锁获取失败（\(DaemonRegistration.daemonLockPath) 被占用）——另一 daemon 实例运行中，退出")
    exit(1)
}

// 0.5 自举策略目录（幂等）：嵌入路线无 CLI install 创建目录，缺目录仅影响持久化
// （PolicyStore 写失败记日志，内存策略继续生效）——显式创建并可见化失败，不静默。
do {
    try FileManager.default.createDirectory(
        atPath: "/Library/Application Support/Cellar",
        withIntermediateDirectories: true
    )
} catch {
    lifecycleLog.error("自举策略目录失败（\(error)）——策略持久化将不可用（内存策略继续生效）")
}

// 1/2. 单一属主 + 启动即校对（失败只记日志，绝不退出）。
// daemonCore 为 nonisolated(unsafe) 全局：信号/C 回调等非隔离上下文经它访问属主。
daemonCore = DaemonCore(policyStore: PolicyStore(url: PolicyStore.defaultURL), log: lifecycleLog)
let core = daemonCore!
core.startup()

// 3. raw XPC 监听；失败 → fatal。
let server = XPCServer(core: core, log: lifecycleLog)
server.start()

// 4. 信号（先忽略默认处置，再建 DispatchSourceSignal——评审 C-4 定版顺序）。
installSignal(SIGTERM) {
    guard let core = daemonCore else { return }
    core.restoreAndExit()
}
installSignal(SIGINT) {
    guard let core = daemonCore else { return }
    core.restoreAndExit()
}
installSignal(SIGHUP) {
    daemonCore?.reloadPolicy()
}

// 5. 心跳：30 秒主 RunLoop 定时器（percent 整数变化即 batteryLevelChanged；
//    periodicTick 兜底——WP4 触发词表内，规格 §0.5）。
scheduleHeartbeat(core: core)

// 6. 电源通知（主 RunLoop source）。
registerPowerNotifications(core: core)

lifecycleLog.info("daemon 启动完成：version=\(DaemonXPC.daemonVersion, privacy: .public)")

// 常驻：主 RunLoop 驱动定时器与电源通知；XPC/信号在各自队列。
CFRunLoopRun()

// MARK: - 跨进程互斥（防线 b，flock 实现）

/// 对 `DaemonRegistration.daemonLockPath` 加 flock(LOCK_EX|LOCK_NB)：成功 → fd 存
/// 全局（进程存活期不关闭）；失败（另一实例持有/路径打开失败）→ 返回 false。
private func acquireDaemonLock() -> Bool {
    let fd = open(DaemonRegistration.daemonLockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return false }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return false
    }
    daemonLockFD = fd
    return true
}

// MARK: - 信号（评审 C-4：先 signal(SIG_IGN) 再 DispatchSourceSignal；全局队列）

private func installSignal(_ sig: Int32, _ handler: @escaping @Sendable () -> Void) {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
    source.setEventHandler(handler: handler)
    source.resume()
    signalSources.append(source)
}

// MARK: - 心跳（主 RunLoop 定时器，30 秒）

private func scheduleHeartbeat(core: DaemonCore) {
    var context = CFRunLoopTimerContext(
        version: 0,
        info: UnsafeMutableRawPointer(Unmanaged.passUnretained(core).toOpaque()),
        retain: nil, release: nil, copyDescription: nil
    )
    let timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 30, 30, 0, 0,
        { _, info in
            guard let info else { return }
            Unmanaged<DaemonCore>.fromOpaque(info).takeUnretainedValue().sampleAndEnforce()
        },
        &context
    )
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
}

// MARK: - 电源通知（逐消息 ack 纪律，规格 §3 表；评审 D-1：kIOPMNoneLastCall 不存在）

// IOMessage.h 的 kIOMessage* 常量为函数式宏（iokit_common_msg），Swift 无法导入；
// 数值 = sys_iokit(0xE0000000) | sub_iokit_common(0) | 消息号（IOReturn.h/mach error.h 宏展开）。
private let kIOMessageCanSystemSleep: UInt32 = 0xE000_0270
private let kIOMessageSystemWillSleep: UInt32 = 0xE000_0280
private let kIOMessageSystemHasPoweredOn: UInt32 = 0xE000_0300

private func powerCallback(
    context: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let core = daemonCore else { return }
    let token = Int(bitPattern: messageArgument)

    switch messageType {
    case kIOMessageCanSystemSleep:
        // 本 daemon 永不 veto 空闲睡眠：立即放行。
        _ = IOAllowPowerChange(powerRootPort, token)
    case kIOMessageSystemWillSleep:
        core.sleepNow()   // 同步执行（含回读），睡眠通知等待其完成。
        // 无条件放行：失败仅 error 日志——不 ack 会卡死系统睡眠（评审 D-1/P0）。
        let kr = IOAllowPowerChange(powerRootPort, token)
        if kr != kIOReturnSuccess {
            lifecycleLog.error("IOAllowPowerChange 失败 kr=\(kr, privacy: .public)——睡眠放行失败")
        }
    case kIOMessageSystemHasPoweredOn:
        // DarkWake 频繁触发可接受，全量 enforce 成本低。
        core.wakeUp()
    default:
        break
    }
}

private func registerPowerNotifications(core: DaemonCore) {
    var notificationPort: IONotificationPortRef?
    var notifier: io_object_t = 0
    powerRootPort = IORegisterForSystemPower(nil, &notificationPort, powerCallback, &notifier)

    guard powerRootPort != 0, let notificationPort else {
        lifecycleLog.error("电源通知注册失败——睡眠期间限充策略不会执行（daemon 将继续运行）")
        return
    }
    let source = IONotificationPortGetRunLoopSource(notificationPort)
    guard let source else {
        lifecycleLog.error("获取电源通知 RunLoop source 失败")
        return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source.takeUnretainedValue(), .commonModes)
}