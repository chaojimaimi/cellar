// 菜单栏图标快捷预设菜单模型（0.23.16 B8 §2.3 纯函数层）。
//
// 落点纪律（方案第一轮 P1 钉死）：本文件**必须在 CellarCore**——CellarCoreCheck
// 唯一依赖 ["CellarCore"]，直测场景才能 import；落 CellarUI 则场景不可达。模型
// **不携带 title**——CellarL10n / CellarNumericFormat 在 CellarUI（AppKit 组装层
// 可达 CellarUI，本模块依赖闭包仅 Foundation），title 生成移入 App 层组装薄层
//（StatusItemController.buildQuickMenu：CellarNumericFormat.percent / catalog key）。
//
// 禁用矩阵（方案 §2.2 第一轮 P2 修正表述）：
// - daemonStatus 失联（upperLimit / mode 双 nil 代理——组装层同源于一个
//   DaemonStatus，双 nil ⇔ daemonStatus == nil）→ 整区禁用；
// - mode == "disabled" → 禁用（面板预设同族，ControlSectionView isModeDisabled）；
// - busy → 禁用（**有意新增门，勿对齐面板**：面板预设无 busy 门——busy 由防抖
//   排程单次延后重排消化；菜单无防抖宿主、点击即入 runControl 单槽队列，busy 期
//   入队会被 latest-wins 覆盖未发命令，禁用更诚实。总开关族 busy 禁用为既有先例）；
// - actionActive（一次性动作在轨）→ 禁用（面板预设同族，
//   ControlSectionView isActionActive）。
// 四字段（value / isSelected / enabled / section）覆盖组装层全判定面。

import Foundation

/// 单个快捷预设项的判定结果（纯值，组装层据此生成 title / state / isEnabled）。
public struct MenuPresetItem: Equatable, Sendable {
    /// 菜单分区标识（现仅快捷限充一区；组装层按 section 挂 section header）。
    public enum Section: String, Sendable {
        case quickLimit
    }

    /// 预设上限值（% 数值语义，60...100——60 地板红线由 LimitPolicy 预检再守）。
    public let value: Int
    /// 当前 daemon 上限与本项相等（菜单 ✓ 态）。
    public let isSelected: Bool
    /// 禁用矩阵判定（见文件头）。
    public let enabled: Bool
    /// 所属分区。
    public let section: Section

    public init(value: Int, isSelected: Bool, enabled: Bool, section: Section) {
        self.value = value
        self.isSelected = isSelected
        self.enabled = enabled
        self.section = section
    }
}

/// 快捷预设菜单判定纯函数集（无状态、无记忆——每次菜单弹出由组装层以
/// daemonStatus 现值求值，防状态陈旧，方案 §2.2 动态刷新条款）。
public enum MenuPresetModel {
    /// 菜单专属预设值（§2.2：90/75/100 为**菜单专属值，不镜像面板**——面板
    /// 零改动纪律，面板上下文有滑杆邻位；面板侧维持 ControlSectionView
    /// 既有 80/70/60 三钮原样）。
    public static let presetValues = [60, 70, 75, 80, 90, 100]

    /// 判定纯函数：输入 daemonStatus 现值投影 + 两项 App 侧实时态，输出六项
    /// 判定结果（顺序即菜单呈现顺序）。
    ///
    /// - Parameters:
    ///   - upperLimit: daemonStatus?.upperLimit（nil = 失联代理之一）。
    ///   - mode: daemonStatus?.mode（nil = 失联代理之一；"disabled" = 总开关关）。
    ///   - busy: StatusController.busy（控制提交在途）。
    ///   - actionActive: 一次性动作在轨（StatusController.action != nil）。
    public static func items(
        upperLimit: Int?,
        mode: String?,
        busy: Bool,
        actionActive: Bool
    ) -> [MenuPresetItem] {
        // 失联代理（方案 §2.3：nil 经 upperLimit/mode 双 nil 代理）——整区禁用。
        let linkLost = upperLimit == nil && mode == nil
        let modeDisabled = mode == "disabled"
        return presetValues.map { value in
            MenuPresetItem(
                value: value,
                isSelected: upperLimit == value,
                enabled: !(linkLost || modeDisabled || busy || actionActive),
                section: .quickLimit
            )
        }
    }
}
