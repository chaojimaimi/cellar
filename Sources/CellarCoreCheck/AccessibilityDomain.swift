// CellarCoreCheck —— 0.23.15「B7 打磨无障碍批」a11y 源钉场景域（方案 §2.1/§5.2）
//
// CellarUICheck 快照对比对 a11y 元数据失明（元数据零像素不进渲染面）——源钉面
// 为唯一机械防回归通道：读 CellarUI / App 源文本断言标记在位。覆盖清单（方案
// §1.1 缺口表逐项）：
// ① 图标裸按钮标签（日程行删除钮，新 key schedule.entry.delete——catalog 增量
//    +1 有意登记，477 → 478）；
// ② 滑杆标签（列位九处：ControlSectionView / OnboardingView / FanSectionView×4 /
//    ThermalSectionView×2 / ChargeScheduleEntryEditor——全部引用既有相邻标签 key，
//    零新 key）；
// ③ Stepper 标签两根（panel.hysteresis 既有 key——裸数字补滞回语义）；
// ④ 选中态 trait 三处（StatsPageView 范围 chip / ChargeScheduleEntryEditor 星期
//    chip / MainWindowView 侧栏导航行——纯颜色选中态补 .isSelected）；
// ⑤ 四曲线卡 combine + accessibilityValue（StatsPageViewCards——最新采样摘要，
//    不逐点暴露；能耗卡留页级不在本钉域）；
// ⑥ catalog 新 key 双语在位（xcstrings JSON 解析直读——l10n 门
//   （CellarUICheck --l10n）为全 key 双语解析端到端，本钉为单 key 源钉面）。
//
// 全部源文件读取（Data 注入仓库相对路径），零渲染、零进程。

import CellarCore
import Foundation

/// 0.23.15 B7 批 a11y 源钉场景域入口（Main.main 调用）。
func runAccessibilityDomainScenarios() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            // 源文件缺席 = 钉面失效（checkout 残缺/文件被改名）——fail 红而非静默绿。
            check(false, "a11y-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    let chargeScheduleListSrc = source("Sources/CellarUI/ChargeScheduleListView.swift")
    let fanSectionSrc = source("Sources/CellarUI/FanSectionView.swift")
    let thermalSectionSrc = source("Sources/CellarUI/ThermalSectionView.swift")
    let editorSrc = source("Sources/CellarUI/ChargeScheduleEntryEditor.swift")
    let controlSectionSrc = source("App/CellarApp/ControlSectionView.swift")
    let onboardingSrc = source("App/CellarApp/OnboardingView.swift")
    let statsPageSrc = source("App/CellarApp/StatsPageView.swift")
    let mainWindowSrc = source("App/CellarApp/MainWindowView.swift")
    let statsCardsSrc = source("App/CellarApp/StatsPageViewCards.swift")

    // a11y-1：删除钮标签（全库唯一图标裸按钮——VoiceOver 否则只读「按钮」）。
    check(chargeScheduleListSrc.contains(#".accessibilityLabel(CellarL10n.s("schedule.entry.delete"))"#),
          "a11y-1", "日程行删除钮 accessibilityLabel（新 key schedule.entry.delete——minus.circle 裸图标钮可读标签）")

    // a11y-2：滑杆标签（方案 §2.1-2 列位——引用既有相邻标签 key，零新 key）。
    check(fanSectionSrc.contains(#".accessibilityLabel(CellarL10n.s("fan.threshold"))"#)
              && fanSectionSrc.contains(#".accessibilityLabel(CellarL10n.s("fan.speed"))"#)
              && fanSectionSrc.contains(#".accessibilityLabel(CellarL10n.s("fan.stage2"))"#)
              && fanSectionSrc.contains(#".accessibilityLabel(CellarL10n.s("fan.stage2Rise"))"#),
          "a11y-2", "风扇四根滑杆 accessibilityLabel（threshold/speed/stage2/stage2Rise——既有标签 key 引用）")
    check(thermalSectionSrc.contains(#".accessibilityLabel(CellarL10n.s("thermal.pause"))"#)
              && thermalSectionSrc.contains(#".accessibilityLabel(CellarL10n.s("thermal.resume"))"#),
          "a11y-2", "热两根滑杆 accessibilityLabel（pause/resume——既有标签 key 引用）")
    check(editorSrc.contains(#".accessibilityLabel(CellarL10n.s("chargeSchedule.action.limitMode"))"#),
          "a11y-2", "日程编辑器上限滑杆 accessibilityLabel（chargeSchedule.action.limitMode——既有标签 key 引用）")
    check(controlSectionSrc.contains(".accessibilityLabel(theme.word(.limitLabel))"),
          "a11y-2", "面板上限滑杆 accessibilityLabel（theme.word(.limitLabel)——相邻标签词同源）")
    check(onboardingSrc.contains(".accessibilityLabel(theme.word(.limitLabel))"),
          "a11y-2", "引导页上限滑杆 accessibilityLabel（theme.word(.limitLabel)——与面板滑杆同词）")

    // a11y-3：Stepper 标签两根（panel.hysteresis 既有 key——裸数字补滞回语义）。
    check(controlSectionSrc.contains(#".accessibilityLabel(CellarL10n.s("panel.hysteresis"))"#)
              && onboardingSrc.contains(#".accessibilityLabel(CellarL10n.s("panel.hysteresis"))"#),
          "a11y-3", "两处 Stepper accessibilityLabel（panel.hysteresis——面板 + 引导页）")

    // a11y-4：选中态 trait 三处（isSelected 条件附加——纯颜色选中态对读屏失明）。
    check(statsPageSrc.contains(".accessibilityAddTraits(rangeWindow == window ? .isSelected : [])"),
          "a11y-4", "统计页范围 chip 选中态 trait（isSelected 条件附加）")
    check(editorSrc.contains(".accessibilityAddTraits(selected ? .isSelected : [])"),
          "a11y-4", "日程编辑器星期 chip 选中态 trait（isSelected 条件附加）")
    check(mainWindowSrc.contains(".accessibilityAddTraits(selection == page ? .isSelected : [])"),
          "a11y-4", "主窗侧栏导航行选中态 trait（isSelected 条件附加）")

    // a11y-5：四曲线卡 combine + accessibilityValue（最新采样摘要——读屏零数据
    // 缺口收口；计数恰四 = 电量/窖温/功耗/容量四卡）。
    check(statsCardsSrc.components(separatedBy: ".accessibilityElement(children: .combine)").count - 1 == 4
              && statsCardsSrc.components(separatedBy: ".accessibilityValue(a11ySummary)").count - 1 == 4,
          "a11y-5", "四曲线卡 accessibilityElement(children: .combine) + accessibilityValue 恰四组（最新采样摘要——不逐点暴露）")

    // a11y-6：catalog 新 key 双语在位（xcstrings JSON 解析直读——zh-Hans/en 双值
    // 断言；477 → 478 有意增量，commit 消息登记）。
    do {
        let catalogURL = repoRoot
            .appendingPathComponent("Sources/CellarUI/Resources/Localizable.xcstrings")
        if let data = try? Data(contentsOf: catalogURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let strings = root["strings"] as? [String: Any],
           let entry = strings["schedule.entry.delete"] as? [String: Any],
           let localizations = entry["localizations"] as? [String: Any],
           let zh = (localizations["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any],
           let en = (localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any] {
            check((zh["value"] as? String) == "删除此日程"
                      && (en["value"] as? String) == "Delete this schedule",
                  "a11y-6", "新 key schedule.entry.delete 双语在位（zh「删除此日程」/ en Delete this schedule——catalog 增量 +1 有意登记）")
        } else {
            check(false, "a11y-6", "catalog schedule.entry.delete 键结构缺席（双语源钉红）")
        }
    }
}
