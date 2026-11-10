import Foundation

// 菜单 profile 区模型（0.23.18 方案 §2.4 纯函数层）——照 MenuPresetModel 先例：
// 落点钉死 CellarCore（CellarCoreCheck 唯一依赖 ["CellarCore"]，判定场景才能
// import）；模型**不携带 title**——CellarL10n 在 CellarUI（组装层可达），title =
// profile.name 用户数据原样。
//
// **MenuPresetModel.Section 不扩 enum**（方案 §2.4 定版——profile 项独立模型独立
// 数组，不与六预设混列表；语义不同不合并。本文对调研 B4「扩 Section enum」建议
// 的偏离，理由：Section 复用会把 name/id 形态与 value 形态塞进同一项类型，字段
// 两态语义被迫合并）。
//
// 禁用矩阵（与 MenuPresetModel 四门对齐，**mode == "disabled" 不禁用**——切到
// active profile 正是从 disabled 走出的合法路径，显式 disable/隐式启用矩阵
// ProfileModel.applyPlan 已如实处理）：
// - status == nil（失联）→ 整区禁用（组装层同源一个 DaemonStatus）；
// - busy → 禁用（runControl 单槽在途——整包切换不接受排队，R6）；
// - actionActive（一次性动作在轨）→ 禁用（setLimits 隐式取消在轨动作的入口
//   禁用面，R4）。

/// 单个菜单 profile 项的判定结果（纯值，组装层据此生成 title/state/isEnabled）。
public struct MenuProfileItem: Equatable, Sendable {
    /// ProfilePayload.id（组装层经 representedObject 承载——id 非 Int，tag 通路
    /// 不适用）。
    public let id: String
    /// 方案名（用户数据原样，非 l10n 键）。
    public let name: String
    /// ✓ 态——**读回派生**（ProfileModel.activeMatch 命中），非意图镜像
    /// （activeProfileID 不参与——「本地意图 ≠ daemon 现值」如实不点亮，防意图
    /// 漂移，方案 §2.1 B3-5）。
    public let isSelected: Bool
    /// 禁用矩阵判定（见文件头）。
    public let enabled: Bool

    public init(id: String, name: String, isSelected: Bool, enabled: Bool) {
        self.id = id
        self.name = name
        self.isSelected = isSelected
        self.enabled = enabled
    }
}

/// 菜单 profile 区判定纯函数集（无状态、无记忆——每次菜单弹出由组装层以
/// daemonStatus 现值求值，防状态陈旧；MenuPresetModel 同款动态刷新条款）。
public enum MenuProfileModel {
    /// 判定纯函数：输入方案集 + daemonStatus 现值 + 两项 App 侧实时态，输出逐项
    /// 判定（顺序 = profiles 列表序）。
    ///
    /// - Parameters:
    ///   - profiles: ProfileController.profiles（空 → 空数组——组装层整区省略，
    ///     菜单形态对无 profile 用户零变化）。
    ///   - status: DaemonStatus? **直入**——✓ 派生在模型内部经
    ///     ProfileModel.activeMatch 完成，结构性杜绝调用方误接意图镜像
    ///     activeProfileID（评审 P2-3）；linkLost 由 status == nil 内部派生。
    ///   - busy: StatusController.busy（控制提交在途）。
    ///   - actionActive: 一次性动作在轨（StatusController.action != nil）。
    public static func items(
        profiles: [ProfilePayload],
        status: DaemonStatus?,
        busy: Bool,
        actionActive: Bool
    ) -> [MenuProfileItem] {
        let activeID = status.flatMap { ProfileModel.activeMatch(profiles: profiles, current: $0) }
        return profiles.map { profile in
            MenuProfileItem(
                id: profile.id,
                name: profile.name,
                isSelected: profile.id == activeID,
                enabled: !(status == nil || busy || actionActive)
            )
        }
    }
}
