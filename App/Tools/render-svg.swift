#!/usr/bin/env swift
//
// render-svg.swift — WebKit SVG 渲染/校验工具（make-icons.sh 的管线组件）
//
// 用途：
//   render <in.svg> <out.png> <pixelSize>  用完整 WebKit 管线渲染 SVG 为
//     指定像素尺寸的 PNG（支持 SVG filter 辉光、渐变、透明背景）
//   verify <png> <pixelSize>               校验 PNG 像素尺寸、四角透明、
//     中心不透明（退出码 0 = 合格；1 = 不合格；2 = 无法读取）
//
// 实现要点：
//   - SVG 直接作为文档载入 WKWebView（不经 <img> 包装）。实测 WebKit 只在
//     视口大小 == SVG 固有尺寸时才完成绘制，故视口一律取 SVG 根元素的
//     width/height，目标尺寸由快照重绘得到。
//   - 视图挂在离屏 NSWindow 上（无窗口的 WKWebView takeSnapshot 会得到
//     空白或杂讯），并等排版稳定后再截屏。
//   - 快照按屏幕 scale 输出（固有尺寸 ×2），统一重绘到目标像素尺寸。
// 零外部依赖（仅系统框架）。
//

import AppKit
import WebKit

let arguments = CommandLine.arguments

// ---- verify 模式 ----
if arguments.count >= 4, arguments[1] == "verify" {
    guard let expected = Int(arguments[3]), expected > 0,
          let image = NSImage(contentsOfFile: arguments[2]),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { exit(2) }
    guard bitmap.pixelsWide == expected, bitmap.pixelsHigh == expected else { exit(1) }
    let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
    let corners = [(0, 0), (1, 0), (0, 1), (1, 1),
                   (w - 1, 0), (w - 2, 0), (w - 1, 1),
                   (0, h - 1), (1, h - 1),
                   (w - 1, h - 1), (w - 2, h - 1), (w - 1, h - 2)]
    var alphaSum = 0
    for (x, y) in corners {
        if let color = bitmap.colorAt(x: x, y: y) {
            alphaSum += Int(color.alphaComponent * 255)
        }
    }
    // 角部平均 alpha < 25% 视为透明（容忍小尺寸下抗锯齿羽化）。
    guard alphaSum / corners.count < 64 else { exit(1) }
    // 中心必须不透明：空白渲染（文档未绘制）会被拦下。
    if let center = bitmap.colorAt(x: w / 2, y: h / 2) {
        exit(Int(center.alphaComponent * 255) >= 160 ? 0 : 1)
    }
    exit(1)
}

guard arguments.count == 5, arguments[1] == "render",
      let pixelSize = Int(arguments[4]), pixelSize > 0 else {
    let usage = "usage: swift render-svg.swift render <in.svg> <out.png> <size>\n" +
        "       swift render-svg.swift verify <png> <size>\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: arguments[2])
let outputURL = URL(fileURLWithPath: arguments[3])

// SVG 根元素的固有尺寸（width/height 属性），用作 WebKit 视口大小。
func intrinsicSize(of url: URL) -> Int? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    func firstNumber(_ attribute: String) -> Int? {
        guard let range = text.range(of: attribute + "=\"") else { return nil }
        let rest = text[range.upperBound...]
        var digits = ""
        for char in rest {
            if char.isNumber { digits.append(char) } else { break }
        }
        return Int(digits)
    }
    guard let w = firstNumber("width"), let h = firstNumber("height"), w == h else { return nil }
    return w
}

guard let viewport = intrinsicSize(of: inputURL), viewport > 0 else {
    FileHandle.standardError.write(Data(
        "render-svg.swift: 无法从 SVG 根元素解析 width/height\n".utf8))
    exit(2)
}

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    private let inputURL: URL
    private let outputURL: URL
    private let pixelSize: Int
    private(set) var finished = false

    init(viewport: Int, inputURL: URL, outputURL: URL, pixelSize: Int) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.pixelSize = pixelSize
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: viewport, height: viewport),
            configuration: configuration
        )
        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: viewport, height: viewport),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
        // 透明背景：只导出 SVG 自身内容。drawsBackground 是非公开 KVC 键，
        // 属透明快照的事实标准手法；若 Apple 未来移除该键会抛
        // NSUndefinedKeyException，届时需改用不透明背景+合成方案。
        webView.setValue(false, forKey: "drawsBackground")
    }

    func start() {
        window.orderFront(nil)
        webView.loadFileURL(inputURL, allowingReadAccessTo: inputURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等文档排版/首帧绘制稳定后再截屏。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            DispatchQueue.main.async { [weak self] in
                self?.capture()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("navigation failed: \(error)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("web content process terminated")
    }

    /// 失败路径必须显式退出，否则主循环会无输出挂死。
    private func fail(_ message: String) {
        FileHandle.standardError.write(Data("render-svg.swift: \(message)\n".utf8))
        exit(1)
    }

    private func capture() {
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = webView.bounds
        webView.takeSnapshot(with: snapshot) { [weak self] image, error in
            guard let self else { return }
            guard let image, error == nil else {
                FileHandle.standardError.write(Data(
                    "render-svg.swift: snapshot failed: \(String(describing: error))\n".utf8))
                exit(1)
            }
            // 快照像素尺寸 = 视口 × 屏幕 scale；重绘到目标像素尺寸。
            guard let target = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelSize,
                pixelsHigh: pixelSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                FileHandle.standardError.write(Data("render-svg.swift: bitmap alloc failed\n".utf8))
                exit(1)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
            image.draw(
                in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
            guard let tiff = target.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("render-svg.swift: PNG encode failed\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: outputURL)
            } catch {
                FileHandle.standardError.write(Data("render-svg.swift: write failed: \(error)\n".utf8))
                exit(1)
            }
            self.finished = true
        }
    }
}

_ = NSApplication.shared
let renderer = Renderer(
    viewport: viewport,
    inputURL: inputURL,
    outputURL: outputURL,
    pixelSize: pixelSize
)
renderer.start()

let deadline = Date().addingTimeInterval(30)
while !renderer.finished {
    if Date() > deadline {
        FileHandle.standardError.write(Data("render-svg.swift: render timed out after 30s\n".utf8))
        exit(1)
    }
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
exit(0)