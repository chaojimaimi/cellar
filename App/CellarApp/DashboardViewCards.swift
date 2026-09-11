import CellarCore
import CellarUI
import SwiftUI

// 实时仪表板「三卡片」分区（Phase 5 v1.2 §3.4——DashboardView 组装超 400 行，
// 按分区拆文件，红线 6）：电池规格 / 电池健康 / 适配器（battery 态空态卡）。
// 数据投影（snapshot/flowState/batteryPowerW/healthPercent 等）在
// DashboardView.swift；本文件仅消费，无独立数据源。

extension DashboardView {

    // MARK: - 三卡片

    var cards: some View {
        HStack(alignment: .top, spacing: 14) {
            specCard
            healthCard
            adapterCard
        }
    }

    private func cardTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func kv(_ key: String, value: String, unit: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
            if let unit {
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.secondaryText.opacity(0.2)).frame(height: 1)
        }
    }

    // ---- 电池规格卡 ----

    private var specCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle(CellarL10n.s("dashboard.card.spec"), icon: "battery.75")
            kv(CellarL10n.s("statusline.voltage"),
               value: snapshot.map { String(format: "%.2f", Double($0.voltageMV) / 1000) } ?? CellarL10n.s("common.nodata"),
               unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.volt"))
            kv(CellarL10n.s("statusline.current"),
               value: currentValue,
               unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.ampere"))
            kv(CellarL10n.s(powerSpecLabelKey),
               value: powerValue,
               unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.watt"))
            kv(CellarL10n.s("dashboard.card.spec.capacity"),
               value: snapshot?.rawCurrentCapacityMAh.map(grouped) ?? CellarL10n.s("common.nodata"),
               unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.milliampereHour"))
            kv(CellarL10n.s("dashboard.card.spec.design"),
               value: snapshot.map { grouped($0.designCapacityMAh) } ?? CellarL10n.s("common.nodata"),
               unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.milliampereHour"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
    }

    /// 功率/电流符号（v0.19.3 §D5 kind 全函数，与流向图同源裁决）：
    /// `assist → −`（放电补差）；`charging → +`；`holding / battery →
    /// isCharging ? + : −`（kind == .charging ⟹ isCharging，故与「遥测源按 kind /
    /// 回退值按 isCharging」的分源意图等价；`.battery` 态 edge 非 nil 但来自 V×I，
    /// 必须落在 isCharging 支，R3 P1）。
    private var batterySign: Double {
        switch flowModel.kind {
        case .assist: return -1
        case .charging: return 1
        case .holding, .battery: return (snapshot?.isCharging ?? false) ? 1 : -1
        }
    }

    /// 电流幅值不变（|amperageMA|），符号用同一 kind 全函数（与功率行同向）。
    private var currentValue: String {
        guard let snapshot else { return CellarL10n.s("common.nodata") }
        let magnitude = Double(abs(snapshot.amperageMA)) / 1000
        return String(format: "%+.2f", batterySign * magnitude)
    }

    /// 功率幅值取 `flowModel.batteryEdgeW ?? batteryPowerW` 绝对值（遥测源按 kind
    /// 同快照；回退/缺席落 V×I 现状）。
    private var powerValue: String {
        guard snapshot != nil else { return CellarL10n.s("common.nodata") }
        let watts = abs(flowModel.batteryEdgeW ?? batteryPowerW)
        guard watts >= 0.05 else { return "0.0" }
        return String(format: "%+.1f", batterySign * watts)
    }

    /// 功率行标签（v0.19.3 §D5）：值来源为遥测 BP（kind ∈ {charging, assist} 且
    /// 遥测齐全）→ 「功率 · 遥测」，否则「功率」。⚠️ 含 SP 合取项——BP 在场 /
    /// SP 缺席走回退（值仍是 V×I，场景 19），漏项即错标（R3 P1）。
    private var powerSpecLabelKey: String.LocalizationValue {
        let telemetryReady = snapshot?.telemetry?.systemPowerInMW != nil
            && snapshot?.telemetry?.batteryPowerMW != nil
        if flowModel.kind == .assist || (flowModel.kind == .charging && telemetryReady) {
            return "dashboard.card.spec.power.telemetry"
        }
        return "dashboard.card.spec.power"
    }

    /// 千分位分组（mock 5,103——NumberFormatter 分组形态）。
    private func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // ---- 电池健康卡 ----

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle(CellarL10n.s("dashboard.tile.health"), icon: "shield.lefthalf.filled")
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(healthPercent.map(String.init) ?? CellarL10n.s("common.nodata"))
                    // v1.9 D-B4：健康卡 44pt 主读出数字面 design 随 token（App 层
                    // 最显要数字读出面；A/B nil 落回 .default 零扰动）。
                    .font(.system(size: 44, weight: .semibold, design: theme.numericFontDesign ?? .default))
                    .monospacedDigit()
                    .foregroundStyle(theme.accent)
                Text(CellarL10n.s("dashboard.unit.percent"))
                    .font(.system(size: 18))
                    .foregroundStyle(theme.secondaryText)
            }
            // 容量进度条（mock barsub：track 底 + accent 渐隐填充——token 近似）。
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: proxy.size.width * healthFraction)
                }
            }
            .frame(height: 7)
            // P1-1：nominal/design 缺席（nodata/字段缺席）时 key 位显「—」——
            // 禁止编造「标称 0 · 设计 0 mAh」（§3.5 诚实纪律；照适配器卡
            // nodata 分支形态）。
            if let nominalMAh, let designMAh {
                kv(CellarL10n.s("dashboard.card.health.nominalDesign", nominalMAh, designMAh),
                   value: CellarL10n.s("dashboard.tile.cycle.sub"))
            } else {
                kv(CellarL10n.s("common.nodata"),
                   value: CellarL10n.s("dashboard.tile.cycle.sub"))
            }
            kv(CellarL10n.s("dashboard.card.health.maxCapacity"),
               value: snapshot?.maxCapacityPercent.map(String.init) ?? CellarL10n.s("common.nodata"),
               unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.percent"))
            kv(CellarL10n.s("statusline.cycle"),
               value: snapshot.map { "\($0.cycleCount)" } ?? CellarL10n.s("common.nodata"),
               unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.count"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
    }

    private var healthFraction: CGFloat {
        guard let health = healthPercent else { return 0 }
        return CGFloat(min(max(health, 0), 100)) / 100
    }

    private var nominalMAh: Int? {
        snapshot?.nominalChargeCapacityMAh ?? snapshot?.rawMaxCapacityMAh
    }

    private var designMAh: Int? {
        snapshot?.designCapacityMAh
    }

    // ---- 适配器卡 ----

    @ViewBuilder
    private var adapterCard: some View {
        if let adapter = snapshot?.adapter {
            VStack(alignment: .leading, spacing: 8) {
                cardTitle(CellarL10n.s("statusline.adapter"), icon: "powerplug")
                kv(CellarL10n.s("dashboard.card.adapter.rated"),
                   value: adapter.watts.map(String.init) ?? CellarL10n.s("common.nodata"),
                   unit: adapter.watts == nil ? nil : CellarL10n.s("dashboard.unit.watt"))
                kv(CellarL10n.s("dashboard.card.adapter.voltage"),
                   value: adapter.voltageMV.map { String(format: "%.1f", Double($0) / 1000) } ?? CellarL10n.s("common.nodata"),
                   unit: adapter.voltageMV == nil ? nil : CellarL10n.s("dashboard.unit.volt"))
                kv(CellarL10n.s("dashboard.card.adapter.current"),
                   value: adapter.currentMA.map { String(format: "%.2f", Double($0) / 1000) } ?? CellarL10n.s("common.nodata"),
                   unit: adapter.currentMA == nil ? nil : CellarL10n.s("dashboard.unit.ampere"))
                kv(CellarL10n.s("dashboard.card.adapter.type"),
                   value: CellarL10n.s(adapter.isWireless == true ? "dashboard.card.adapter.type.wireless" : "dashboard.card.adapter.type.wired"))
                kv(CellarL10n.s("dashboard.card.adapter.status"),
                   value: adapterStatusWord,
                   unit: nil)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let panelBackground = theme.panelBackground { panelBackground }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
        } else if snapshot == nil {
            // nodata：规格未知——kv 结构保留、数值全「—」（§3.5）。
            VStack(alignment: .leading, spacing: 8) {
                cardTitle(CellarL10n.s("statusline.adapter"), icon: "powerplug")
                kv(CellarL10n.s("dashboard.card.adapter.rated"), value: CellarL10n.s("common.nodata"))
                kv(CellarL10n.s("dashboard.card.adapter.voltage"), value: CellarL10n.s("common.nodata"))
                kv(CellarL10n.s("dashboard.card.adapter.current"), value: CellarL10n.s("common.nodata"))
                kv(CellarL10n.s("dashboard.card.adapter.type"), value: CellarL10n.s("common.nodata"))
                kv(CellarL10n.s("dashboard.card.adapter.status"), value: CellarL10n.s("common.nodata"))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let panelBackground = theme.panelBackground { panelBackground }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
        } else {
            // 未接入空态卡（§3.4 battery 态，照 mock ADP_EMPTY：图形 + 两句提示）。
            VStack(spacing: 8) {
                Image(systemName: "powerplug")
                    .font(.system(size: 34))
                    .foregroundStyle(theme.tertiaryText)
                Text(CellarL10n.s("dashboard.card.adapter.empty"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryText)
                Text(CellarL10n.s("dashboard.card.adapter.emptyHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background {
                if let panelBackground = theme.panelBackground { panelBackground }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
        }
    }

    private var adapterStatusWord: String {
        switch flowState {
        case .charging: return CellarL10n.s("dashboard.card.adapter.status.charging")
        case .holding: return CellarL10n.s("dashboard.card.adapter.status.holding")
        // 0.19.4 §1.2：assist → 「直供 + 电池补入」（新 catalog key）。
        case .assist: return CellarL10n.s("dashboard.card.adapter.status.assist")
        case .battery, nil: return CellarL10n.s("common.nodata")
        }
    }
}
