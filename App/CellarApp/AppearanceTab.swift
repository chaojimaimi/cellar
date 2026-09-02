import CellarCore
import CellarUI
import SwiftUI

/// 外观 Tab（WP3 §4 定版）：风格 Picker（原生 / 酒窖琥珀）即时生效——
/// `styleController.setStyle` 内存先行驱动 environment 全树重算（§3.3 链路），
/// 持久化经共享 store 原子 update；loaded 前 Picker 禁用（防半程态回写，评审
/// P2-3 登记）。下方色板行 4 色块（accent / 渐变起止 / 面板底）随风格与系统
/// 深浅色刷新（色板值出自 Theme.swift token，G2 不新增字面量落点）。
///
/// 本文件含风格词元（G1 白名单成员）；组件层其余文件禁止引入。
struct AppearanceTab: View {
    @EnvironmentObject private var styleController: StyleController
    @Environment(\.cellarTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form {
            Picker(CellarL10n.s("settings.panelStyle"), selection: Binding(
                get: { styleController.style },
                set: { styleController.setStyle($0) }
            )) {
                Text(CellarL10n.s("settings.styleNative")).tag(PanelStyle.native)
                Text(CellarL10n.s("settings.styleAmber")).tag(PanelStyle.amber)
            }
            .disabled(!styleController.loaded)

            // 色板行：随选中风格即时刷新（Picker 未生效前色板与环境值可能不一致
            // ——以选中风格 resolve 为准，而非当前 environment）。
            VStack(alignment: .leading, spacing: 6) {
                Text(CellarL10n.s("settings.swatchHint"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
                HStack(spacing: 6) {
                    let swatches = CellarTheme.swatchColors(
                        style: styleController.style, scheme: scheme
                    )
                    ForEach(swatches.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(swatches[index])
                            .frame(width: 30, height: 18)
                    }
                }
            }

            if let feedback = styleController.saveFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(theme.alert)
            }
        }
        .padding()
    }
}
