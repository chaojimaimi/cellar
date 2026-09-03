import Foundation
import os
@preconcurrency import XPC
import CellarCore

/// raw XPC 监听（串行队列）+ euid/组门 + 鉴权失败限流 + 命令分发（规格 §0.2/§0）。
///
/// 安全契约：
/// - `getStatus` 任意本地用户可调；`setLimits/disable/enable` 仅 **euid==0 或
///   admin 组（gid 80）** 成员（Phase 2 P0 决策：面板是用户态进程，UI 控制需要
///   admin 组放宽；放宽的攻击面上限为充电策略操纵，无提权/无数据泄露），
///   否则错误回包（ok=false + 原文）。
/// - 鉴权失败限流：同一连接变更命令被拒累计 ≥10 次 → `xpc_connection_cancel`
///   （防非特权用户 DoS 心跳）。
/// - 消息校验经 `DaemonXPC.validateRequest`（xpc_get_type 白名单）；非法回错误包，不崩溃。
/// - 监听器收到连接无效错误（Mach 服务名未注册——非 launchd 手动直跑，或重复实例）
///   → **fatal 退出**（防双写者野进程）。
///
/// 并发：全部事件处理器挂在同一串行队列；对 DaemonCore 的调用经其内部锁串行化。
final class XPCServer: @unchecked Sendable {
    /// 鉴权失败取消阈值（评审：限流）。
    private static let authFailureLimit = 10
    /// admin 组 GID（40 年 macOS 惯例固定值；放宽判定目标）。
    private static let adminGroupGID: gid_t = 80

    private let core: DaemonCore
    private let log: os.Logger
    private let queue = DispatchQueue(label: "com.cellar.daemon.xpc")
    /// 监听器（+1 所有权；进程存活期持有，从不释放）。
    private var listener: xpc_connection_t?

    init(core: DaemonCore, log: os.Logger) {
        self.core = core
        self.log = log
    }

    /// 创建并 resume Mach 服务监听。Swift 导入下句柄非可选——创建期失败不可观测，
    /// 实际失败（服务名未注册/已被占用）经监听器错误事件暴露 → fatal 退出。
    func start() {
        let listener = xpc_connection_create_mach_service(
            DaemonXPC.machServiceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        self.listener = listener
        xpc_connection_set_event_handler(listener) { [weak self] object in
            self?.handleListenerEvent(object)
        }
        xpc_connection_resume(listener)
    }

    // MARK: - 监听器事件

    private func handleListenerEvent(_ object: xpc_object_t) {
        switch xpc_get_type(object) {
        case XPC_TYPE_CONNECTION:
            accept(peer: object)
        case XPC_TYPE_ERROR:
            // 服务名未注册（非 launchd 手动直跑）或已注册冲突（重复实例）：
            // 此时进程无权作为 Mach 服务运行 → fatal（防双写者野进程）。
            log.fault("Mach 服务监听失败（\(self.describeError(object))）——非 launchd 手动直跑，拒绝运行")
            exit(1)
        default:
            break
        }
    }

    /// 新对端：euid 快照（连接建立时）→ 事件处理器（同一串行队列）→ resume。
    private func accept(peer: xpc_connection_t) {
        let peerInfo = Peer(euid: xpc_connection_get_euid(peer), connection: peer)
        xpc_connection_set_target_queue(peer, queue)
        xpc_connection_set_event_handler(peer) { [weak self] object in
            self?.handlePeerEvent(object, peer: peerInfo)
        }
        xpc_connection_resume(peer)
        log.info("新连接：euid=\(peerInfo.euid, privacy: .public)")
    }

    // MARK: - 对端事件（请求分发）

    private func handlePeerEvent(_ object: xpc_object_t, peer: Peer) {
        let type = xpc_get_type(object)
        if type == XPC_TYPE_ERROR {
            // 对端断开：连接由 libxpc 回收（拒绝计数随 peer 释放，无需清理）。
            return
        }
        guard type == XPC_TYPE_DICTIONARY else {
            send(errorReply("非法请求类型"), to: peer.connection)
            return
        }
        guard let request = DaemonXPC.validateRequest(object) else {
            send(errorReply("非法请求：字段类型或长度不符合协议"), to: peer.connection)
            return
        }

        switch request.cmd {
        case "getStatus":
            sendStatus(core.status(), to: peer)

        case "setLimits":
            guard authorize(peer, operation: "set") else { return }
            // UInt64 → Int：越界（如 2^63+）按参数越界拒绝，防 Int 转换崩溃。
            guard let upper = Int(exactly: request.upper), let hysteresis = Int(exactly: request.hysteresis) else {
                send(errorReply("上限/滞回参数越界"), to: peer.connection)
                return
            }
            // WP2' 自动放电：auto 键值域校验（UINT64 类型混淆已由 validateRequest
            // 整包拒绝；值 0/1 之外拒绝——validAutoFlag 与 CellarCoreCheck 同源，
            // 仿 Int(exactly) 拒绝风格）。
            if let auto = request.auto, !Discharge.validAutoFlag(auto) {
                send(errorReply("自动放电参数越界"), to: peer.connection)
                return
            }
            do {
                let status = try core.setLimits(upper: upper, hys: hysteresis, auto: request.auto)
                sendStatus(status, to: peer)
            } catch {
                // LimitPolicyError（含 60 地板）等 → 原文回传（CLI 打印原文 + 退出 1）。
                send(errorReply(String(describing: error)), to: peer.connection)
            }

        case "disable":
            respondChange(peer: peer, operation: "disable", body: { try core.disable() })

        case "enable":
            respondChange(peer: peer, operation: "enable", body: { try core.enable() })

        case "fullOnce":
            // WP2 一次性动作（鉴权门同变更命令：root / admin 组）。
            respondChange(peer: peer, operation: "fullOnce", body: { try core.fullOnce() })

        case "dischargeToLimit":
            // WP2' 放电到上限（鉴权门同 fullOnce；无参数——目标 = 当前策略快照）。
            respondChange(peer: peer, operation: "dischargeToLimit", body: { try core.dischargeToLimit() })

        case "cancelAction":
            respondChange(peer: peer, operation: "cancelAction", body: { try core.cancelAction() })

        case "startCalibration":
            // WP3 校准（鉴权门同变更命令；无参数——相位序列由 daemon 执行）。
            respondChange(peer: peer, operation: "startCalibration", body: { try core.startCalibration() })

        case "cancelCalibration":
            respondChange(peer: peer, operation: "cancelCalibration", body: { try core.cancelCalibration() })

        default:
            send(errorReply("未知命令：\(request.cmd)"), to: peer.connection)
        }
    }

    /// 变更类命令（euid 门 + 执行 + 回包）。
    private func respondChange(
        peer: Peer,
        operation: String,
        body: () throws -> DaemonStatus
    ) {
        guard authorize(peer, operation: operation) else { return }
        do {
            let status = try body()
            sendStatus(status, to: peer)
        } catch {
            send(errorReply(String(describing: error)), to: peer.connection)
        }
    }

    /// euid/组门 + 鉴权失败限流（规格 §0.2/§0）：root 或 admin 组（gid 80）成员可调
    /// 变更命令；其余 → 错误回包 + 拒绝计数；累计 ≥10 次 → 取消连接。返回 false =
    /// 已回错误包，调用方不再执行。
    ///
    /// 判定失败（用户查找/组列举失败）与原逻辑一致走限流路径——查不到即拒绝，
    /// 绝不静默放行。
    private func authorize(_ peer: Peer, operation: String) -> Bool {
        guard peer.euid == 0 || isAdminGroupMember(euid: peer.euid) else {
            peer.rejections += 1
            send(errorReply("需要管理员权限（admin 组）才能执行 \(operation)。当前账户无此权限，请联系管理员。"), to: peer.connection)
            if peer.rejections >= Self.authFailureLimit {
                log.error("鉴权拒绝累计 \(peer.rejections) 次，取消连接（限流）")
                xpc_connection_cancel(peer.connection)
            }
            return false
        }
        return true
    }

    /// admin 组（gid 80）成员判定（P0 定版，规格 §0）：euid → getpwuid_r 取用户名
    /// 与主 gid → getgrouplist 检查 80 ∈ 组数组。
    ///
    /// ⚠️ getgrouplist basegid 约束（P1 安全脚枪，v1.2 评审）：basegid 必须传
    /// `pw_gid`（getpwuid_r 返回值），**禁止传 80**——getgrouplist 恒将 basegid
    /// 计入输出数组，传 80 即任意用户都「命中 80」→ 鉴权静默全开放。
    ///
    /// 缓冲区不足（getgrouplist 返回 -1 且 *ngroups 已更新为所需数）时按其倍增
    /// 重试；超过 4096 仍失败 → 拒绝（保守方，组数超上限的用户不存在于本环境）。
    private func isAdminGroupMember(euid: uid_t) -> Bool {
        var pwd = passwd()
        var buffer = [CChar](repeating: 0, count: 1024)
        var result: UnsafeMutablePointer<passwd>?
        // result 非 nil 即 pwd 已被填充（指向传入的 &pwd，非独立分配）。
        guard getpwuid_r(euid, &pwd, &buffer, buffer.count, &result) == 0, result != nil else {
            return false
        }
        guard let name = String(cString: pwd.pw_name, encoding: .utf8) else { return false }

        var count = 64
        while count <= 4096 {
            var groups = [gid_t](repeating: 0, count: count)
            var ngroups = Int32(count)
            let rc = getgrouplist(name, Int32(pwd.pw_gid), &groups, &ngroups)
            if rc >= 0 {
                return groups.prefix(Int(ngroups)).contains(Self.adminGroupGID)
            }
            count = max(Int(ngroups) * 2, count * 2)
        }
        return false
    }

    // MARK: - 回包

    /// 发送回包。⚠️ xpc 对象由 Swift ARC 管理——发送后不得手动 xpc_release
    /// （对象随调用方作用域自动回收；双重释放会崩溃）。
    private func send(_ reply: xpc_object_t, to peer: xpc_connection_t) {
        xpc_connection_send_message(peer, reply)
    }

    /// 状态编码 + okReply 回传（编码失败（不可达）→ 错误回包，不崩溃）。
    private func sendStatus(_ status: DaemonStatus, to peer: Peer) {
        guard let json = DaemonXPC.encodeStatus(status) else {
            send(errorReply("状态编码失败"), to: peer.connection)
            return
        }
        send(DaemonXPC.okReply(json), to: peer.connection)
    }

    private func errorReply(_ message: String) -> xpc_object_t {
        DaemonXPC.errorReply(message)
    }

    private func describeError(_ object: xpc_object_t) -> String {
        if xpc_equal(object, XPC_ERROR_CONNECTION_INVALID) { return "服务名未注册或已被占用" }
        if xpc_equal(object, XPC_ERROR_CONNECTION_INTERRUPTED) { return "连接中断" }
        return "未知错误"
    }
}

/// 单连接上下文（euid 快照 + 鉴权拒绝计数；仅串行队列访问，无需锁）。
/// @unchecked Sendable：只被 XPC 串行队列上的处理器使用（事件处理器闭包要求 Sendable）。
private final class Peer: @unchecked Sendable {
    let euid: uid_t
    let connection: xpc_connection_t
    var rejections = 0

    init(euid: uid_t, connection: xpc_connection_t) {
        self.euid = euid
        self.connection = connection
    }
}