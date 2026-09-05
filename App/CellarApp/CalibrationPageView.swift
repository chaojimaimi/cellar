import CellarCore
import CellarUI
import SwiftUI

// MARK: - 校准页（Phase 5 v1.4 §3，替换 .calibration 占位）

/// 校准页：页头（页题 + intro 说明行）+ 三张卡（校准状态 / 自动调度 / 上次校准）。
/// 组装形态照统计页页头先例（ScrollView + maxWidth 720 + panel 卡容器）；本文件
/// 仅组装与 App 侧派生，三卡内容全部来自参数驱动组件（CellarUI）——
/// - 状态卡：复用 CalibrationSectionView（参数照 PanelSections.CalibrationSection
///   面板桥接同款派生，两步确认流同一语汇）；
/// - 调度卡：ScheduleSectionView（门控二态在组件内：daemonStatus.calibrationSchedule
///   字段缺席 = legacy 态——勿把未配置当旧 daemon，UD-7）；
/// - 上次校准卡：LastCalibrationView。
///
/// 墙钟时间与下次预估文案在本页组装（本地时区钟面语义留在 App 侧，组件与快照
/// 保持纯值注入）；状态数据源 = StatusController 既有 1s/60s 轮询（主窗口可见
/// 即在跑），本页不新增循环（方案 §7-M3-7）。
struct CalibrationPageView: View {
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text(CellarL10n.s("calibration.page.intro"))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                statusCard
                scheduleCard
                lastCard
            }
            .padding(24)
            // 页面容器纪律：照统计页（maxWidth 720，宽窗不无限拉伸）。
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    // MARK: - 页头（照统计页页头形态；校准已实页化无版本徽章）

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(CellarL10n.s("main.page.calibration"))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Spacer()
        }
    }

    // MARK: - 三卡（panel 容器照统计页 panel 形态，去图表 minHeight——文本卡自然高）

    private func panel(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(theme.secondaryText)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
    }

    /// 状态卡：CalibrationSectionView 复用（capability/mode 门控、idle/confirm/running
    /// 三态与两步确认块全部组件内承载；参数派生照面板 CalibrationSection 同款）。
    private var statusCard: some View {
        panel(title: CellarL10n.s("calibration.title")) {
            CalibrationSectionView(
                calibrationActive: statusController.daemonStatus?.isCalibrationAction == true,
                phase: statusController.daemonStatus?.calibrationPhase,
                percent: statusController.batterySnapshot?.percent
                    ?? statusController.daemonStatus?.lastPercent,
                capabilityPresent: statusController.capabilities?
                    .contains(DaemonXPC.capabilityCalibration) == true,
                modeActive: statusController.daemonStatus?.mode == "active",
                actionIdle: statusController.action == nil,
                busy: statusController.busy,
                onStart: { statusController.calibrateStart() },
                onCancel: { statusController.calibrateCancel() },
                showsTitle: false
            )
        }
    }

    /// 调度卡：onApply 桥接 applyCalibrationSchedule（全键下发，setFan runControl
    /// 先例）；门控二态由组件按 schedule == nil 判定。
    private var scheduleCard: some View {
        panel(title: CellarL10n.s("calibration.schedule.title")) {
            ScheduleSectionView(
                schedule: statusController.daemonStatus?.calibrationSchedule,
                busy: statusController.busy,
                nextEstimateText: nextEstimateText,
                onApply: { statusController.applyCalibrationSchedule($0) },
                showsTitle: false
            )
        }
    }

    /// 上次校准卡：timeText nil（无 lastCalStart = 无记录）→ 组件占位行。
    private var lastCard: some View {
        panel(title: CellarL10n.s("calibration.last.title")) {
            LastCalibrationView(
                timeText: lastCalTimeText,
                outcomeText: lastCalOutcomeText,
                durationSeconds: lastCalDurationSeconds,
                showsTitle: false
            )
        }
    }

    // MARK: - App 侧文案派生（本地时区钟面语义留此，不进组件）

    /// 下次预估行（三态，方案 §3.1）：就绪（daemon 同一纯函数判定）→「已就绪」；
    /// 未就绪 → 「下次自动校准：M 月 d 日 HH:00 前后」；负差值（时钟回拨，预估
    /// nil）→ nil → 组件「—」；调度关/旧 daemon → nil（行不显示）。
    private var nextEstimateText: String? {
        guard let status = statusController.daemonStatus,
              let schedule = status.calibrationSchedule, schedule.enabled else { return nil }
        let anchor = status.lastCalStart.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        // 就绪判定照 daemon 同一纯函数（无第二实现——单一真相，方案 §2.1）。
        if calibrationAutoStartReady(now: Date(), lastStartedAt: anchor, schedule: schedule) {
            return CellarL10n.s("calibration.schedule.ready")
        }
        guard let date = status.nextAutoCalibrationEstimate else { return nil }
        let calendar = Calendar.current
        return CellarL10n.s(
            "calibration.schedule.next",
            calendar.component(.month, from: date),
            calendar.component(.day, from: date),
            calendar.component(.hour, from: date)
        )
    }

    /// 上次校准起始墙钟文案（本地时区；系统 locale 语义对生产正确，不进快照面）。
    private var lastCalTimeText: String? {
        guard let start = statusController.daemonStatus?.lastCalStart else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start))
            .formatted(.dateTime.month().day().hour().minute())
    }

    /// 终态词映射（rawValue 五词与 CalibrationOutcome 一一对齐；未知串显式 nil
    /// → 组件「—」降级，不猜测语义）。
    private var lastCalOutcomeText: String? {
        guard let raw = statusController.daemonStatus?.lastCalOutcome,
              let outcome = CalibrationOutcome(rawValue: raw) else { return nil }
        switch outcome {
        case .done: return CellarL10n.s("calibration.last.outcome.done")
        case .cancel: return CellarL10n.s("calibration.last.outcome.cancel")
        case .timeout: return CellarL10n.s("calibration.last.outcome.timeout")
        case .safety: return CellarL10n.s("calibration.last.outcome.safety")
        case .crashRecovery: return CellarL10n.s("calibration.last.outcome.crash-recovery")
        }
    }

    /// 耗时秒数（startedAt→endedAt；end 缺席/早于 start → nil「—」降级）。
    private var lastCalDurationSeconds: Int? {
        guard let status = statusController.daemonStatus,
              let start = status.lastCalStart, let end = status.lastCalEnd, end >= start
        else { return nil }
        return end - start
    }
}
