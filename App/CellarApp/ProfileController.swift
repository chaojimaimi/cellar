import CellarCore
import CellarUI
import Foundation
import os

/// 多 Profile 控制器（0.23.18 方案 §2.2；AppConfig 第五写者——style/launchAtLogin/
/// onboardingCompleted/menuBar* 四写者先例齐全，actor RMW 单实例不可交错）。
/// AppKit 域单例化先例（0.23.16 B8）：static shared——ProfileSectionView /
/// StatusItemController 经静态可达取数，**不新增第七个 environmentObject**
/// （方案 §1 红线 6；DisplaySettingsController 同构照搬）。
///
/// CRUD 全部经 `AppConfigStore.shared.update()`（原子读改写——只写 profiles /
/// activeProfileID 本域字段，其余写者字段保持）；成功后同步内存 @Published
/// （update 返回落库 config——单一真相回填）。损坏回退如实登记：payload decode
/// 失败 → load() 整体回默认（既有语义，偏好可重建）——可接受，方案不改 load()。
@MainActor
final class ProfileController: ObservableObject {
    /// 进程级单例（StatusController.shared / DaemonInstaller.shared 先例形态）。
    static let shared = ProfileController()

    /// 方案集（列表序 = 菜单/管理页呈现序；activeMatch 首匹配语义按此序）。
    @Published private(set) var profiles: [ProfilePayload] = []
    /// 活动方案 UX 意图镜像（**✓ 标注不以它为准**——✓ 由 ProfileModel.activeMatch
    /// 读回匹配派生；本字段只承载「用户最后点了哪个」）。
    @Published private(set) var activeIntentID: String?
    /// 持久化配置是否已加载（CRUD 在 loaded 前拒绝——防半程态回写，显示控制器先例）。
    @Published private(set) var loaded = false

    /// 迁移门（config.profiles nil ⇔ 未迁移——首启静默捕获一次性语义；捕获成功
    /// 即置 true，失败保持 false 下次 ingest 重试）。
    private var migrated = false

    private let store: AppConfigStore
    private let log = Logger(subsystem: "com.cellar", category: "app-config")

    init(store: AppConfigStore = AppConfigStore.shared) {
        self.store = store
        // load 必须随实例诞生自启动（DisplaySettingsController.init 注记先例——
        // static shared 形态下正式实例 init 必自跑）。
        load()
    }

    /// 启动加载：profiles nil = 未迁移过（迁移门保持 false，maybeCaptureDefault
    /// 首个完备读回时落「默认」方案）。
    private func load() {
        // 强捕获 self（一次性短任务；DisplaySettingsController.load 同款——
        // static shared 常驻实例无释放面）。
        Task { [store] in
            let config = await store.load()
            self.profiles = config.profiles ?? []
            self.activeIntentID = config.activeProfileID
            self.migrated = config.profiles != nil
            self.loaded = true
        }
    }

    // MARK: - CRUD（落库 + 内存同步；拒绝经 StatusController 横幅通道——非静默）

    /// 新建（「当前设置另存为」编辑形态 v1）：capture 完备性门 nil → 拒绝横幅
    /// （control.profile.captureUnavailable）；上限 maxProfiles → 拒绝横幅
    /// （control.profile.limitReached）。命名校验第一道在管理页行内红字
    /// （isValidName——方案 §2.5），此处防御性重检。
    func create(from status: DaemonStatus, name: String) {
        guard loaded else { return }
        guard let captured = ProfileModel.capture(from: status) else {
            reportRejection(CellarL10n.s("control.profile.captureUnavailable"))
            return
        }
        guard profiles.count < ProfileModel.maxProfiles else {
            reportRejection(CellarL10n.s("control.profile.limitReached", ProfileModel.maxProfiles))
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProfileModel.isValidName(trimmed) else {
            reportRejection(CellarL10n.s("control.profile.nameInvalid"))
            return
        }
        var payload = captured
        payload.name = trimmed
        let snapshot = payload
        Task { [store] in
            do {
                let config = try await store.update { $0.profiles = ($0.profiles ?? []) + [snapshot] }
                self.applySynced(config)
            } catch {
                self.logWriteFailure(error)
            }
        }
    }

    /// 重命名（校验同 create；新名 trim 后落库）。
    func rename(id: String, name: String) {
        guard loaded else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProfileModel.isValidName(trimmed) else {
            reportRejection(CellarL10n.s("control.profile.nameInvalid"))
            return
        }
        var updated = profiles
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].name = trimmed
        persistProfiles(updated)
    }

    /// 复制（名 = 原名 + l10n「副本」后缀，新 UUID；上限门同 create——达上限拒绝）。
    func duplicate(id: String) {
        guard loaded else { return }
        guard profiles.count < ProfileModel.maxProfiles else {
            reportRejection(CellarL10n.s("control.profile.limitReached", ProfileModel.maxProfiles))
            return
        }
        guard let source = profiles.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID().uuidString
        copy.name = CellarL10n.s("control.profile.duplicateSuffix", source.name)
        persistProfiles(profiles + [copy])
    }

    /// 删除（删除活动意图 profile 时一并清 activeProfileID——意图镜像不得指向
    /// 已删实体；✓ 由读回派生不受影响）。
    func delete(id: String) {
        guard loaded else { return }
        let updated = profiles.filter { $0.id != id }
        persistProfiles(updated, clearingIntent: activeIntentID == id)
    }

    /// 意图更新（链尾 finishProfileChain 与管理页/菜单切换共用的单一入口；落库
    /// activeProfileID + 内存镜像）。
    func setActiveIntent(id: String?) {
        activeIntentID = id
        let target = id
        Task { [store] in
            do {
                let config = try await store.update { $0.activeProfileID = target }
                self.activeIntentID = config.activeProfileID
            } catch {
                self.logWriteFailure(error)
            }
        }
    }

    /// 切换（整包下发编排入口——无单值预检面，LimitPolicy 式预检不适用）：
    /// 直投 StatusController.applyProfile（三门/收敛守卫/失败停链全在编排器）。
    func switchTo(_ payload: ProfilePayload, current: DaemonStatus) {
        StatusController.shared.applyProfile(payload: payload, current: current)
    }

    // MARK: - 首启静默迁移（B2；StatusController.ingest 尾部挂点）

    /// profiles == nil（未迁移）∧ 现值读回完备 → 落名为 l10n「默认」的方案
    /// （activeProfileID 保持 nil——✓ 由读回匹配自然点亮）；capture nil（旧
    /// daemon 形态）→ 保持未迁移，下次 ingest 重试（一次性成功即止）。幂等单发
    /// 守卫：migrated 派发即置位（防在途窗重复捕获——lastSuppressionRecoveryAt
    /// 先例），写失败回置 false 重试；无 daemon 用户无默认方案（不造数，R7）。
    func maybeCaptureDefault(_ status: DaemonStatus) {
        guard loaded, !migrated else { return }
        guard var payload = ProfileModel.capture(from: status) else { return }
        payload.name = CellarL10n.s("control.profile.defaultName")
        migrated = true
        let snapshot = payload
        Task { [store] in
            do {
                let config = try await store.update { $0.profiles = [snapshot] }
                self.applySynced(config)
            } catch {
                self.migrated = false   // 下次 ingest 重试（R7）
                self.logWriteFailure(error)
            }
        }
    }

    // MARK: - 私有（落库/同步/拒绝）

    /// 全量 profiles 落库（CRUD 通用尾程；clearingIntent = 删除活动意图时一并清
    /// activeProfileID）。内存同步在 update 返回后（落库 config 单一真相回填）。
    private func persistProfiles(_ updated: [ProfilePayload], clearingIntent: Bool = false) {
        let snapshot = updated
        let intentSnapshot = clearingIntent ? nil : activeIntentID
        Task { [store] in
            do {
                let config = try await store.update {
                    $0.profiles = snapshot
                    $0.activeProfileID = intentSnapshot
                }
                self.applySynced(config)
            } catch {
                self.logWriteFailure(error)
            }
        }
    }

    /// 落库成功后的内存同步（update 返回 config = 单一真相；写者竞态下以落库值
    /// 为准，防他写者回写窗口内的内存漂移）。
    private func applySynced(_ config: AppConfig) {
        profiles = config.profiles ?? []
        activeIntentID = config.activeProfileID
        migrated = config.profiles != nil
    }

    /// 拒绝横幅（StatusController.controlFeedback 通道——非静默；capture/上限门
    /// 的指定上屏面，方案 §2.5）。文案由调用点经 CellarL10n.s 预格式化（门面
    /// variadic 形态不可透传数组——逐点直呼）。
    private func reportRejection(_ message: String) {
        StatusController.shared.reportLocalRejection(message)
    }

    private func logWriteFailure(_ error: Error) {
        log.error("profile 配置写盘失败：\(error.localizedDescription, privacy: .public)")
    }
}
