// MARK: - macOS 27 菜单栏渲染 spike（0.19.10 M0——菜单栏百分比消失根因定位）
//
// 运行（无需 root）：
//   swiftc -parse-as-library -o /tmp/menubar-spike Tools/spike-macos27-menubar.swift
//   /tmp/menubar-spike
// 常驻运行；观察菜单栏右侧 A–E 五个新菜单项哪些可见，逐个点击看内容文字标识，
// 然后对照本文件头部表格回报结果。Ctrl+C 退出。
//
// 五个变体（A 即生产 0.18.7 精确形态；E 即生产 label 的完整 HStack）：
//   A = 自绘位图（black+alpha，isTemplate=true）——生产 glyph 形态
//   B = 同一位图 isTemplate=false（彩色非模板）
//   C = SF Symbol（bolt.fill，系统符号对照）
//   D = 纯 Text("98")（文本基线）
//   E = 生产完整形态：HStack { 位图 A ; Text("98") }（glyph + 百分比）
//
// 判读表（回报格式）：
//   菜单栏插入顺序 = 声明顺序（从左到右 A→B→C→D→E）；点击各项弹出的内容文字
//   即身份标识（标签无标题，靠点击内容分辨）。
//   可见 → 该渲染路在 macOS 27 存活；不可见 → 该路死（生产对应修法）：
//   A 死 + E 只见数字 → 27 上模板位图不渲染（生产改 SF 符号或非模板位图）
//   A 活 + E 只见位图无数字 → 27 上 label 中 Text 被丢弃（百分比需换承载形态）
//   A 活 + E 有图有数字 → 生产形态在 27 无损（问题在 Cellar 数据链，另行排查）

import SwiftUI

// MARK: - 生产同款位图（black+alpha 模板；形态照 MenuBarBatteryIconRenderer 简化）

func makeBitmap(template: Bool) -> NSImage {
    let size = NSSize(width: 26, height: 16.5)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.black.setStroke()
    NSColor.black.setFill()
    let body = NSBezierPath(roundedRect: NSRect(x: 0.7, y: 0.7, width: 20.6, height: 12.1),
                            xRadius: 3.2, yRadius: 3.2)
    body.lineWidth = 1.4
    body.stroke()
    NSBezierPath(roundedRect: NSRect(x: 22.3, y: 4.5, width: 2.4, height: 4.5),
                 xRadius: 1.2, yRadius: 1.2).fill()
    NSBezierPath(rect: NSRect(x: 2.8, y: 2.8, width: 12, height: 7.9)).fill()
    image.unlockFocus()
    image.isTemplate = template
    return image
}

// MARK: - 五变体 App（每个 MenuBarExtra 场景 = 一个独立菜单栏项；内容文字 = 身份标识）

@main
struct MenubarSpikeApp: App {
    var body: some Scene {
        MenuBarExtra(isInserted: .constant(true)) {
            Text("A：位图模板（生产 glyph 形态）——看到本窗口即 A 在位")
        } label: {
            Image(nsImage: makeBitmap(template: true))
        }
        MenuBarExtra(isInserted: .constant(true)) {
            Text("B：位图彩色（非模板）——看到本窗口即 B 在位")
        } label: {
            Image(nsImage: makeBitmap(template: false))
        }
        MenuBarExtra(isInserted: .constant(true)) {
            Text("C：SF Symbol bolt.fill——看到本窗口即 C 在位")
        } label: {
            Image(systemName: "bolt.fill")
        }
        MenuBarExtra(isInserted: .constant(true)) {
            Text("D：纯文本 98——看到本窗口即 D 在位")
        } label: {
            Text("98")
        }
        MenuBarExtra(isInserted: .constant(true)) {
            Text("E：生产完整形态（位图 + 98）——看到本窗口即 E 在位")
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: makeBitmap(template: true))
                Text("98").monospacedDigit()
            }
        }
    }
}
