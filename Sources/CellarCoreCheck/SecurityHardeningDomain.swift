// CellarCoreCheck —— 0.23.11「B5 安全纵深批」场景域（方案 §2 各场景段）
//
// 按域拆独立文件（照 FullChargeAutoRestoreDomain 源钉先例；直测 + 源码钉面）。
// 覆盖清单（方案 §2 逐项，每项注明机制：纯函数直测 / 源码钉面；随批分 commit
// 递增——①② 随 commit 1/2 先行，本 commit 收全 ①..④）：
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

    // ---- ③ B5-4：daemon.log 自写统一 0640 源钉（方案 §2.4 场景段）----
    let topoffExtSrc = source("Sources/cellar-daemon/DaemonCore+Topoff.swift")

    // 纵深-6：persistLog 双写 + 串行锁——stderr 保留（主路径永不失效）+
    // writeDaemonLog 第二落点；static NSLock 串行化（DaemonCore 主锁 ~40 调用点
    // + watchdog 独立队列遗言例外）；失败一次性告警标记防刷屏。
    check(topoffExtSrc.contains(#"FileHandle.standardError.write(Data((message + "\n").utf8))"#)
            && topoffExtSrc.contains("writeDaemonLog(message)"),
          "纵深-6", "persistLog 双写（stderr 保留 + writeDaemonLog 自写）在位")
    check(topoffExtSrc.contains("private static let logLock = NSLock()")
            && topoffExtSrc.contains("logLock.lock()")
            && topoffExtSrc.contains("defer { logLock.unlock() }"),
          "纵深-6", "writeDaemonLog 自带 static NSLock 全程串行（watchdog 并发例外收口）")
    check(topoffExtSrc.contains("daemonLogFailureAnnounced"),
          "纵深-6", "失败一次性告警标记在位（daemonLogFailureAnnounced 防刷屏）")

    // 纵深-7：目录防护先行（防新增 CWE-59/61 root 写原语）——verifyRootOwnedDirectory
    // 恰好两处判定（既有目录直接判 + createDirectory 后复核一次，单调用窗闭窗）+
    // root 上下文建档归一化 root:wheel 0755。
    check(topoffExtSrc.components(separatedBy: "verifyRootOwnedDirectory(path: daemonLogDirectory)").count - 1 == 2,
          "纵深-7", "目录防护判定恰好两处（既有目录判 + create 后复核——P3-b 单调用窗闭窗）")
    check(topoffExtSrc.contains("atPath: daemonLogDirectory, withIntermediateDirectories: true")
            && topoffExtSrc.contains("chown(daemonLogDirectory, 0, 0)")
            && topoffExtSrc.contains("chmod(daemonLogDirectory, 0o755)"),
          "纵深-7", "缺席时 createDirectory + 归一化 root:wheel 0755（自举先例同款）")
    // 纵深-7 补（0.23.11 发版前 code-reviewer P1 收口）：①新建分支 chown 前属主
    // 拒——createDirectory 对已存在目录静默成功，stat(ENOENT)→create 竞速窗内
    // 攻击者可植入投毒目录，无条件 chown 会洗白 uid 证据（照 CLI install P1-1
    // 纪律）；②门后文件形态守卫——目录复核只查属性面，daemon.log 若为 symlink
    // 则 rotate chown/chmod 与 append open 均跟随 = root 追写原语，lstat S_IFREG
    // 守卫降级返回（与 B5-1 同款纪律）。
    check(topoffExtSrc.contains("createdStatus.st_uid != 0"),
          "纵深-7", "新建分支 chown 前属主拒（uid≠0 → 降级，防竞态投毒目录洗白）")
    check(topoffExtSrc.contains("lstat(daemonLogPath, &fileLinkStatus)")
            && topoffExtSrc.contains("(fileLinkStatus.st_mode & S_IFMT) != S_IFREG"),
          "纵深-7", "门后文件形态守卫（lstat 不跟随 symlink——非 S_IFREG 降级返回）")

    // 纵深-8：rotate ≥8MB + append 属主/权限定版——阈值钉值（8MB 字面量）；
    // rename 前对将轮转文件 chown root:admin + chmod 0640（daemon.log.1 同批收敛）；
    // append open O_CREAT|O_WRONLY|O_APPEND 0o640 → chown(0,80) → chmod 0640 每次
    // double-guard（launchd 历史档 0644 首写即矫正，无需独立自举收敛段）。
    check(topoffExtSrc.contains("daemonLogRotateBytes = 8 * 1024 * 1024"),
          "纵深-8", "rotate 阈值钉值 8MB（8 * 1024 * 1024 字面量）")
    check(topoffExtSrc.contains("logStatus.st_size >= off_t(daemonLogRotateBytes)")
            && topoffExtSrc.contains("rename(daemonLogPath, daemonLogRotatedPath)")
            && topoffExtSrc.contains(#"daemonLogRotatedPath = daemonLogDirectory + "/daemon.log.1""#),
          "纵深-8", "rotate 判定 + rename daemon.log.1（单份覆盖旧档）在位")
    check(topoffExtSrc.components(separatedBy: "chown(daemonLogPath, 0, 80)").count - 1 == 2
            && topoffExtSrc.components(separatedBy: "chmod(daemonLogPath, 0o640)").count - 1 == 2,
          "纵深-8", "root:admin 0640 双保恰好两处（rotate 前 + append 每次 double-guard）")
    check(topoffExtSrc.contains("open(daemonLogPath, O_CREAT | O_WRONLY | O_APPEND, 0o640)")
            && topoffExtSrc.contains(#"daemonLogPath = daemonLogDirectory + "/daemon.log""#),
          "纵深-8", "append open 序列（O_CREAT|O_WRONLY|O_APPEND 0o640）+ 路径常量在位")

    // 纵深-9：双 plist 无 StandardErrorPath（键级断言——App 模板含「无
    // StandardErrorPath」教训注释，字符串级 contains 反断言恒红不成立；两路线
    // 日志统一由 daemon persistLog 自写，launchd 重定向面永久退出）。
    do {
        for plistPath in ["App/Tools/com.cellar.daemon.plist", "Tools/com.cellar.daemon.plist"] {
            let url = repoRoot.appendingPathComponent(plistPath)
            var root: [String: Any]?
            if let data = try? Data(contentsOf: url),
               let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                root = raw as? [String: Any]
            }
            check(root != nil && root?["StandardErrorPath"] == nil,
                  "纵深-9", "\(plistPath)：可解析且无 StandardErrorPath 键")
        }
    }

    // ---- ④ B5-5：install 源路径去 CWD 化（方案 §2.5 场景段）----

    // 纵深-10：helperSourceRoot 推导核心直测——临时 SPM 形态目录树（.build/
    // release/cellar）推导成功路径（symlink 解析 + 三级上溯 + 百分号解码）+ nil
    // 拒绝（可执行位置缺席）。CLI 包装层（组合 .build/release/cellar-daemon +
    // fileExists + print + ExitCode）由纵深-11 源钉。推导核心落
    // CellarCore.DaemonRegistration（同包 executable target 不可 import 的架构
    // 事实——方案 §2.5 直测要求经该拆分落实，偏差登记）。
    do {
        let fakeRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-b55-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fakeRepo.appendingPathComponent(".build/release"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeRepo) }
        let fakeExecutable = fakeRepo.appendingPathComponent(".build/release/cellar")
        try Data("mach-o".utf8).write(to: fakeExecutable)

        expectEqual(
            DaemonRegistration.helperSourceRoot(fromExecutablePath: fakeExecutable.path),
            fakeRepo.path,
            "纵深-10", "SPM 形态目录树推导成功路径（三级上溯 = 仓库根）")
        // symlink 形态（PATH 形态调用时 argv 可执行为 symlink——解析后上溯）。
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-b55-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path, withDestinationPath: fakeExecutable.path)
        defer { try? FileManager.default.removeItem(at: linkURL) }
        expectEqual(
            DaemonRegistration.helperSourceRoot(fromExecutablePath: linkURL.path),
            fakeRepo.path,
            "纵深-10", "symlink 形态可执行解析后推导（P2-b——不解析则三级上溯误拒）")
        expectEqual(
            DaemonRegistration.helperSourceRoot(fromExecutablePath: nil),
            nil as String?,
            "纵深-10", "executablePath nil → nil（CLI 层显式报错拒装——禁回退 CWD）")
    }

    // 纵深-11：CLI 层源钉——helperSource 调用点无 CWD 字面量/表述残留（推导
    // 字面量仅存在于推导函数内）；CWD 相对 plist 读取整链删除；plistTemplate
    // 内嵌常量 + 写入点改用常量；executablePath 来源钉死（_NSGetExecutablePath
    // 形态——不受调用者 CWD/argv[0] 操纵）。
    let cliSource = source("Sources/CellarCLI/Commands/PlaceholderCommands.swift")
    check(cliSource.components(separatedBy: ".build/release/cellar-daemon").count - 1 == 1,
          "纵深-11", "`.build/release/cellar-daemon` 字面量仅在推导函数内（无 CWD 调用点残留）")
    check(!cliSource.contains("相对当前工作目录"),
          "纵深-11", "CWD 相对路径表述零残留（错误文案同步更新）")
    check(!cliSource.contains("plistSource") && !cliSource.contains("String(contentsOfFile"),
          "纵深-11", "CWD 相对 plist 读取整链删除（提权面同源消除）")
    check(cliSource.contains("private static let plistTemplate")
            && cliSource.contains("try plistTemplate.write(toFile: plistPath, atomically: true, encoding: .utf8)"),
          "纵深-11", "plistTemplate 内嵌常量 + 写入点改用常量（消除 CWD 文件读依赖）")
    check(cliSource.contains("helperSourcePath(executablePath: Bundle.main.executableURL?.path)")
            && cliSource.contains("DaemonRegistration.helperSourceRoot(fromExecutablePath: executablePath)"),
          "纵深-11", "executablePath 来源 = Bundle.main.executableURL（_NSGetExecutablePath 形态）+ 推导核心接线在位")

    // 纵深-12：内嵌 plistTemplate == Tools 模板文件内容（双方剥离全部空白字符后
    // 逐字节比对——Tools 为 tab 缩进、Swift 多行常量为字面量缩进，仅 trim 行尾
    // 会恒红；plist 数据面无空白敏感内容，该定义安全）。
    do {
        let templateMarker = #"private static let plistTemplate = """"#
        if let markerRange = cliSource.range(of: templateMarker) {
            let afterMarker = cliSource[markerRange.upperBound...]
            if let closeRange = afterMarker.range(of: #"""""#) {
                let templateText = String(afterMarker[..<closeRange.lowerBound])
                let toolsText = source("Tools/com.cellar.daemon.plist")
                func stripped(_ text: String) -> String {
                    String(text.filter { !($0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r") })
                }
                expectEqual(stripped(templateText), stripped(toolsText),
                            "纵深-12", "内嵌模板 == Tools 文件内容（剥全部空白逐字节一致——防漂移）")
            } else {
                check(false, "纵深-12", "plistTemplate 闭界未找到（多行字面量形态破坏）")
            }
        } else {
            check(false, "纵深-12", "plistTemplate 开界未找到（内嵌常量缺失）")
        }
    }
}
