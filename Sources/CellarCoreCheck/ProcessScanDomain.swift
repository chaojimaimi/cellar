// CellarCoreCheck —— WP5 conflict 进程层扫描场景域（方案 §2.2）
//
// 进程扫描仅匹配层 1 knownIdentifiers（genericKeywords 不用于进程名——power 词根
// 必命中系统必驻进程 powerd，每台正常机器误报，评审 P0-1）；`com.apple.` 前缀
// 豁免对裸 comm 不适用。sysctl 真机枚举不落地为用例（无确定性断言面），注入
// 名单路径覆盖判定逻辑（scanProcesses processNames 参数）。

import CellarCore
import Foundation

/// 进程扫描场景域入口（Main.main 调用）。
func runProcessScanDomainScenarios() {
    // 进程-1：层 1 命中矩阵——knownIdentifiers 命中 / powerd 与词根不命中 /
    // 大小写不敏感 / generic 恒空。
    do {
        let result = ConflictScan.classifyProcesses(
            ["bclm", "powerd", "org.smc.tool", "BCLM"],
            exclude: []
        )
        expectEqual(result.exact, ["BCLM", "bclm"],
                    "进程-1", "层 1 命中（大小写不敏感 contains；powerd/smc 词根不命中）")
        check(result.generic.isEmpty, "进程-1", "进程层永不产出 generic（词根仅目录层专用）")
    }

    // 进程-2：p_comm 截断取舍（MAXCOMLEN 16）——com.battery.helper 截断为
    // com.battery.help 永不命中（已登记取舍：进程层覆盖不到的条目由目录层兜底）。
    do {
        let result = ConflictScan.classifyProcesses(["com.battery.help"], exclude: [])
        check(result.exact.isEmpty, "进程-2", "截断形态不命中（16 字符 comm 取舍文档化）")
    }

    // 进程-3：空/空白 comm 过滤 + self 排除（大小写不敏感）。
    do {
        let result = ConflictScan.classifyProcesses(
            ["", "   ", "bclm", "Cellar", "cellar-daemon", "Cellar-Daemon"],
            exclude: ["cellar", "cellar-daemon"]
        )
        expectEqual(result.exact, ["bclm"], "进程-3", "空 comm 过滤 + self/daemon 排除（大小写不敏感）")
    }

    // 进程-4：重名去重 + 排序。
    do {
        let result = ConflictScan.classifyProcesses(["bclm", "bclm"], exclude: [])
        expectEqual(result.exact, ["bclm"], "进程-4", "重名命中只出现一次（去重排序）")
    }

    // 进程-5：scanProcesses 注入名单路径（与 classifyProcesses 同语义；
    // processNames 缺省 = sysctl 真机枚举路径，见实现注记）。
    do {
        let result = ConflictScan.scanProcesses(
            exclude: ["cellar"],
            processNames: ["powerd", "bclm", ""]
        )
        expectEqual(result.exact, ["bclm"], "进程-5", "scanProcesses 注入名单：powerd/空不命中，bclm 命中")
        check(result.hasConflict, "进程-5", "hasConflict 语义与目录层一致")
    }
}