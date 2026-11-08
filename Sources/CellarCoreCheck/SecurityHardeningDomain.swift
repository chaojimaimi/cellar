// CellarCoreCheck —— 0.23.11「B5 安全纵深批」场景域（方案 §2 各场景段）
//
// 按域拆独立文件（照 FullChargeAutoRestoreDomain 源钉先例；直测 + 源码钉面）。
// 覆盖清单（方案 §2 逐项，每项注明机制：纯函数直测 / 源码钉面；随批分 commit
// 递增——② B5-2/3 XPCServer 源钉、③ B5-4 persistLog/双 plist 源钉、④ B5-5
// 推导核心直测与模板一致性随 commit 2/3 追加）：
// ① B5-1 固定名临时文件 O_EXCL 纵深加固（纵深-1..3）：ActionStore.save 直测
//    （预置 symlink tmp → fail-closed 拒写 + 哨兵未改写；普通残留 → 清理后成功）
//    + 其余 4 处 store O_EXCL 序列源钉（5 处独立实现为格式红线——逐文件钉）。
//
// 全部源文件读取（Data 注入仓库相对路径），不触碰真实 plist、不起 daemon、
// 不触碰 /Library 域（真机 root:admin 0640 断言随发版冒烟清单）。

import CellarCore
import Foundation

/// 0.23.11 B5 批场景域入口（Main.main 调用）。
func runSecurityHardeningDomainScenarios() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            // 源文件缺席 = 钉面失效（checkout 残缺/文件被改名）——fail 红而非静默绿。
            check(false, "纵深-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    // ---- ① B5-1：ActionStore.save O_EXCL 直测（方案 §2.1 场景段）----

    // 纵深-1：预置 symlink tmp（竞态现场复现）——.action.json.tmp 为指向目录外
    // 哨兵文件的符号链接 → save 必须 throw（lstat 守卫不消费 symlink + O_EXCL
    // 对已存在路径恒 EEXIST）且哨兵内容未被改写（跟随与否的强断言——旧
    // data.write 跟随 symlink 即 root 写原语写穿哨兵）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-b51-symlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 哨兵放目录外（temp 根）——若写跟随 symlink，被改写的正是它。
        let sentinelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-b51-sentinel-\(UUID().uuidString).txt")
        try "SENTINEL".write(to: sentinelURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sentinelURL) }
        let temporaryURL = directory.appendingPathComponent(".action.json.tmp")
        try FileManager.default.createSymbolicLink(
            atPath: temporaryURL.path, withDestinationPath: sentinelURL.path)
        let store = ActionStore(url: directory.appendingPathComponent("action.json"))
        let action = OneShotAction(
            kind: "fullOnce", startedAt: Date(timeIntervalSince1970: 0),
            deadline: Date(timeIntervalSince1970: 4 * 3600)
        )

        var threw = false
        do { try store.save(action) } catch { threw = true }
        check(threw, "纵深-1", "预置 symlink tmp → save throw（fail-closed 拒写不跟随）")
        let sentinel = try? String(contentsOf: sentinelURL, encoding: .utf8)
        check(sentinel == "SENTINEL", "纵深-1", "哨兵文件内容未被改写（symlink 未被跟随——写原语关闭）")
        check(!store.fileExists, "纵深-1", "目标 action.json 未被创建（拒写 = 零副作用）")
    }

    // 纵深-2：普通残留文件（上次崩溃态）——remove+O_EXCL 清理语义：预写内容的
    // .action.json.tmp（普通文件）被 lstat 守卫清除后重写 → save 成功 + 回环 +
    // 0644 + 临时文件清理（用例 104 既有语义保持）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-b51-residual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryURL = directory.appendingPathComponent(".action.json.tmp")
        try "stale-crash-residual".write(to: temporaryURL, atomically: true, encoding: .utf8)
        let store = ActionStore(url: directory.appendingPathComponent("action.json"))
        let action = OneShotAction(
            kind: "fullOnce", startedAt: Date(timeIntervalSince1970: 0),
            deadline: Date(timeIntervalSince1970: 4 * 3600)
        )

        do {
            try store.save(action)
        } catch {
            check(false, "纵深-2", "普通残留文件 → save 应成功（remove+O_EXCL 清理语义）——实际 throw \(error)")
        }
        check(store.load() == action, "纵深-2", "save → load 回环 == 原值（残留清除后重写语义）")
        let perms = (try? FileManager.default.attributesOfItem(atPath: store.url.path))?[.posixPermissions] as? Int
        check(perms == 0o644, "纵深-2", "显式 chmod 0644（open mode 受 umask 影响不依赖）")
        check(!FileManager.default.fileExists(atPath: temporaryURL.path), "纵深-2", "临时文件已清理（defer removeItem + rename）")
    }

    // 纵深-3：其余 4 处 store 同构源钉（方案 §2.1 场景段——grep 断言各文件含
    // O_EXCL 序列）。ActionStore 本体行为由纵深-1/2 直测钉死；4 处独立实现为
    // 格式红线注释钉死（OneShot.swift:397 邻域「不复用其写路径」）——逐文件钉
    // 序列标记 + lstat 守卫标记 + fail-closed 注记标记。
    let scheduleStateSrc = source("Sources/CellarCore/Daemon/ScheduleState.swift")
    let daemonPolicySrc = source("Sources/CellarCore/Daemon/DaemonPolicy.swift")
    let topoffStateSrc = source("Sources/CellarCore/Daemon/TopoffState.swift")
    let calibrationStateSrc = source("Sources/CellarCore/Daemon/CalibrationState.swift")
    let b51Pins: [(file: String, text: String)] = [
        ("ScheduleState.swift", scheduleStateSrc),
        ("DaemonPolicy.swift", daemonPolicySrc),
        ("TopoffState.swift", topoffStateSrc),
        ("CalibrationState.swift", calibrationStateSrc),
    ]
    for pin in b51Pins {
        check(pin.text.contains("O_CREAT | O_EXCL | O_WRONLY")
                && pin.text.contains("(tmpStatus.st_mode & S_IFMT) == S_IFREG")
                && pin.text.contains("fail-closed 拒写不跟随"),
              "纵深-3", "\(pin.file)：O_EXCL 序列 + lstat 守卫 + fail-closed 注记三标记在位")
    }

    // ---- ② B5-2/B5-3：XPCServer 源钉（方案 §2.2/§2.3 场景段）----
    // 限流链在串行队列锁内、回包链需活体连接——直测面不存在（executable target
    // 不可 import），按方案钉源码标记。

    // 纵深-4：全局拒绝计数（B5-2）——计数声明/累加/== 一次性判定在位；>= 漂移
    // 显式反向钉（== 非至少一次告警语义，改成 >= 即日志洪水回归）；Peer.rejections
    // per-connection 限流与 cancel 语义标记照旧（对外行为零变化）。
    let xpcServerSrc = source("Sources/cellar-daemon/XPCServer.swift")
    check(xpcServerSrc.contains("private var globalAuthRejections = 0")
            && xpcServerSrc.contains("globalAuthRejections += 1"),
          "纵深-4", "globalAuthRejections 声明 + 拒绝分支累加在位（跨连接进程生存期计数）")
    check(xpcServerSrc.contains("private static let globalAuthAnnounceLimit = 50")
            && xpcServerSrc.contains("if globalAuthRejections == Self.globalAuthAnnounceLimit"),
          "纵深-4", "== 50 一次性告警判定在位（阈值钉 50）")
    check(!xpcServerSrc.contains("globalAuthRejections >="),
          "纵深-4", "无 >= 漂移形态（== 一次性语义反向钉——防日志洪水回归）")
    check(xpcServerSrc.contains("peer.rejections += 1")
            && xpcServerSrc.contains("peer.rejections >= Self.authFailureLimit")
            && xpcServerSrc.contains("xpc_connection_cancel(peer.connection)"),
          "纵深-4", "Peer.rejections / authFailureLimit / cancel 语义标记照旧（对外行为零变化）")

    // 纵深-5：nativeLimit 5s TTL 缓存（B5-3）——缓存字段/TTL 常量/新鲜度判定/
    // 回写点在位；`try Data(...)` 形态钉死（load(rooted:) 为 @autoclosure throws
    // 且内部自捕获读取失败返回 detectorError 形态、本身不向上 throw——保持现网
    // 读失败语义保真，勿改 try?）。
    check(xpcServerSrc.contains("private var nativeLimitCache: (status: NativeLimitStatus, at: Date)?")
            && xpcServerSrc.contains("private static let nativeLimitCacheTTL: TimeInterval = 5"),
          "纵深-5", "nativeLimitCache 元组字段 + TTL 常量 5s 在位")
    check(xpcServerSrc.contains("now.timeIntervalSince(cache.at) < Self.nativeLimitCacheTTL")
            && xpcServerSrc.contains("nativeLimitCache = (wire, now)"),
          "纵深-5", "TTL 新鲜度判定 + 缓存回写在位（5s 内零读盘）")
    check(xpcServerSrc.contains("try Data(contentsOf: NativeChargeLimit.powerdPoliciesURL)"),
          "纵深-5", "`try Data(...)` 原样（load 内部自捕获失败——读失败 detectorError 形态照常入缓存）")

}
