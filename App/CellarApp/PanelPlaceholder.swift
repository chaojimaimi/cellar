import SwiftUI

/// 菜单栏占位面板：本工作包只提供应用壳，真实仪表数据与守护进程接线
/// 在后续工作包完成，这里不读取任何电池信息。
struct PanelPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            ChargingDialPlaceholder()
                .frame(width: 150, height: 150)
                .padding(.top, 4)

            Text("守护进程未接入（后续版本接入）")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("退出 Cellar") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(18)
        .frame(width: 320)
    }
}

/// 静态环形仪表占位：与窖灯图标同构（80% 弧段 + 芯点），琥珀渐变。
private struct ChargingDialPlaceholder: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.08), lineWidth: 14)

            Circle()
                .trim(from: 0, to: 0.8)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.71, green: 0.47, blue: 0.23),
                            Color(red: 0.94, green: 0.75, blue: 0.44),
                        ]),
                        center: .center,
                        startAngle: .degrees(90),
                        endAngle: .degrees(-270)
                    ),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(Color(red: 0.96, green: 0.85, blue: 0.63))
                .frame(width: 12, height: 12)
        }
    }
}