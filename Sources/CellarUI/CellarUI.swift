// CellarUI —— SwiftUI 组件库（WP4 S1a 下沉；SwiftUI-only，依赖闭包 = CellarCore）
//
// 下沉纪律（WP4 方案 §2.1/§7.5）：
// - 组件层禁止风格分支词元（G1 门执法对象），token 一律经 \.cellarTheme
//   environment 消费；Color 字面量仅 Theme.swift（G2 落点）。
// - 组件禁 vibrancy/materials（快照矩阵确定性前提）。
// - 全部用户可见串经 CellarL10n 门面解析（S3 全量替换；Bundle.module 不可跨
//   模块，门面为唯一资源通路）。
//
// 本文件仅作模块说明与纪律锚点，随 S3 组件扩充可承载跨组件共享小件。
