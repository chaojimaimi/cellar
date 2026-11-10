import CellarCore
import CellarUI
import SwiftUI

/// 充电方案管理节（0.23.18 方案 §2.5）：节标题 + 语义提示行 + 方案列表行（名称 +
/// ✓ 读回派生 + 重命名/复制/删除行动词）+ 新建（alert TextField 命名）+ 删除两步
/// 确认（行内嵌展开确认块——uninstall 两步先例形态，主窗常驻无收起问题）+ 空态
/// 引导行。仅接入主窗充电控制页（ControlPageView——方案语义邻接控制区：整包控制
/// 位于单旋钮控制与一次性动作之间，ControlSectionView → Divider → 本节 → Divider
/// → ActionSectionView）；面板（PanelView）零改动。
///
/// **切换 = 行点击**（登记偏差 vs 方案 §2.5「切换按钮」：16 键预算无切换动词键，
/// 新增键破坏 507 硬门——交互形态改走 ChargeScheduleListView 行点击主动作先例，
/// 行动词保留重命名/复制/删除三钮）。切换禁用矩阵 = §2.3 三门（status nil ∨ busy
/// ∨ actionActive——mode == "disabled" 不禁用，切到 active 方案正是从 disabled
/// 走出的合法路径；链在途常态被 busy 门结构性覆盖）；CRUD 按钮不设 busy 门（纯
/// App 侧配置）。
///
/// 数据源：ProfileController.shared 经 @ObservedObject 直注（AppKit 域单例化先例
/// ——StatusItemPanelRoot @ObservedObject StyleController.shared 同款；**不新增
/// 第七个 environmentObject**，方案 §1 红线 6）+ statusController（既有六注入链）。
/// ✓ 标注唯一数据源 = ProfileModel.activeMatch 读回派生（意图镜像 activeIntentID
/// 不参与——防意图漂移）。命名校验：新建 alert 确认钮对非法名禁用（第一道反馈，
/// ProfileController.create 防御重检为第二道）；重命名走行内编辑器（isValidName
/// 失败 → 行内红字——方案 §2.5 校验形态宿主；登记微偏差：方案只指定 alert 形态
/// 于新建，重命名形态未定，行内编辑为「行内红字」唯一可达宿主）。
struct ProfileSectionView: View {
    @EnvironmentObject private var statusController: StatusController
    @ObservedObject private var profileController = ProfileController.shared
    @Environment(\.cellarTheme) private var theme

    /// 新建命名弹窗（macOS alert TextField 形态——方案 §2.5；capture 预检 nil 即
    /// 拒绝横幅不弹窗）。
    @State private var showCreateAlert = false
    @State private var draftName = ""
    /// 行内重命名编辑态（id + 草稿名；行内红字校验宿主）。
    @State private var renamingID: String?
    @State private var renameDraft = ""
    /// 删除两步确认（行内嵌展开确认块；页面级 @State——页面重建即清，残留态无
    /// 跨页滞留面，DaemonSectionView.showUninstallConfirm 同款）。
    @State private var deletePendingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CellarL10n.s("control.profile.title"))
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
            Text(CellarL10n.s("control.profile.hint"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if profileController.profiles.isEmpty {
                // 空列表引导（首启迁移前/用户未建——「从当前设置创建第一个方案」）。
                Text(CellarL10n.s("control.profile.empty"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(profileController.profiles, id: \.id) { profile in
                    row(profile)
                }
            }
            newButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert(CellarL10n.s("control.profile.title"), isPresented: $showCreateAlert) {
            TextField(CellarL10n.s("control.profile.title"), text: $draftName)
            Button(CellarL10n.s("common.confirm")) {
                if let current = statusController.daemonStatus {
                    profileController.create(from: current, name: draftName)
                }
                draftName = ""
            }
            // 非法名禁用确认钮（第一道校验反馈；防御重检在 ProfileController.create）。
            .disabled(!ProfileModel.isValidName(draftName))
            Button(CellarL10n.s("common.cancel"), role: .cancel) { draftName = "" }
        }
    }

    // MARK: - 列表行（行点击切换 + ✓ + 三行动词；重命名展开行内编辑器）

    private func row(_ profile: ProfilePayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if renamingID == profile.id {
                renameEditor(profile)
            } else {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                    if isActive(profile) {
                        // ✓ 读回派生（activeMatch 命中——意图镜像不参与；字形为
                        // 符号非文案，menu 侧同语义走 state .on）。
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(theme.accent)
                            .accessibilityLabel(CellarL10n.s("control.profile.title"))
                    }
                    Spacer(minLength: 8)
                    Button(CellarL10n.s("control.profile.rename")) {
                        renamingID = profile.id
                        renameDraft = profile.name
                    }
                    .controlSize(.small)
                    Button(CellarL10n.s("control.profile.duplicate")) {
                        profileController.duplicate(id: profile.id)
                    }
                    .controlSize(.small)
                    Button(CellarL10n.s("control.profile.delete")) {
                        deletePendingID = profile.id
                    }
                    .controlSize(.small)
                }
                .contentShape(Rectangle())
                // 切换 = 行点击（ChargeScheduleListView 行点击主动作先例；禁用矩阵
                // 三门——busy/actionActive/status nil 任一门开启即不动作，mode
                // disabled 放行；编排器入口三门为第二道防线）。
                .onTapGesture { switchTapped(profile) }
                if deletePendingID == profile.id {
                    deleteConfirmBlock(profile)
                }
            }
        }
    }

    /// 切换（行点击唯一入口）：三门禁用矩阵（§2.3——busy ∨ actionActive ∨
    /// status nil 拒绝，不弹横幅不静默上屏——菜单/管理页禁用矩阵为第一道，编排器
    /// 入口三门 reportLocalRejection 为第二道）。
    private func switchTapped(_ profile: ProfilePayload) {
        guard statusController.daemonStatus != nil,
              !statusController.busy,
              statusController.action == nil else { return }
        if let current = statusController.daemonStatus {
            profileController.switchTo(profile, current: current)
        }
    }

    private func renameEditor(_ profile: ProfilePayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(CellarL10n.s("control.profile.title"), text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { commitRename(profile.id) }
                Button(CellarL10n.s("common.confirm")) { commitRename(profile.id) }
                    .controlSize(.small)
                    .disabled(!ProfileModel.isValidName(renameDraft))
                Button(CellarL10n.s("common.cancel")) {
                    renamingID = nil
                    renameDraft = ""
                }
                .controlSize(.small)
            }
            if !ProfileModel.isValidName(renameDraft) {
                // 行内红字（方案 §2.5 命名校验形态——trim 后非空 ≤40）。
                Text(CellarL10n.s("control.profile.nameInvalid"))
                    .font(.caption2)
                    .foregroundStyle(theme.alert)
            }
        }
    }

    private func commitRename(_ id: String) {
        guard ProfileModel.isValidName(renameDraft) else { return }
        profileController.rename(id: id, name: renameDraft)
        renamingID = nil
        renameDraft = ""
    }

    /// 删除两步确认块（行内嵌展开——uninstall 确认块先例形态：警告信息同等显著，
    /// 主窗常驻无收起问题）。
    private func deleteConfirmBlock(_ profile: ProfilePayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CellarL10n.s("control.profile.deleteConfirm", profile.name))
                .font(.caption)
                .foregroundStyle(theme.warning)
            HStack(spacing: 8) {
                Button(CellarL10n.s("common.confirm")) {
                    deletePendingID = nil
                    profileController.delete(id: profile.id)
                }
                .controlSize(.small)
                Button(CellarL10n.s("common.back")) {
                    deletePendingID = nil
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - 动作（新建 capture 预检 + 切换三门矩阵）

    /// 新建（节尾）：capture 当前 daemon 现值预检（方案 §2.5 序：capture → alert
    /// → create）——nil（旧 daemon 形态）即拒绝横幅不弹窗；create 内防御重检同门。
    private func createTapped() {
        guard let status = statusController.daemonStatus else { return }
        guard ProfileModel.capture(from: status) != nil else {
            statusController.reportLocalRejection(CellarL10n.s("control.profile.captureUnavailable"))
            return
        }
        draftName = ""
        showCreateAlert = true
    }

    private var newButton: some View {
        Button {
            createTapped()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text(CellarL10n.s("control.profile.new"))
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
    }

    /// ✓ 判定（读回派生单点——列表行共用；失联 → 全不点亮）。
    private func isActive(_ profile: ProfilePayload) -> Bool {
        guard let current = statusController.daemonStatus else { return false }
        return ProfileModel.activeMatch(profiles: profileController.profiles, current: current) == profile.id
    }
}
