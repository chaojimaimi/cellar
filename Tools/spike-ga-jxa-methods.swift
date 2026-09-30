#!/usr/bin/env swift
// Cellar macOS 27 GA JXA spike（S3）方法表全量枚举器——E0 发现性步骤的 Swift 旁路（只读）。
// 背景：spike-ga-jxa.js 的全量方法枚举在 arm64e 上因指针地址超 JS Number 精度不可行，
//   退化为「表计数 + 候选 selector 逐个探针」；本工具用 Swift 原生指针绕开该限制，
//   一次性列出目标框架内全部类与全部实例方法名（含类型编码），供 CANDIDATE/SETTER 列表迭代。
// 用法：
//   swift Tools/spike-ga-jxa-methods.swift [framework 名 ...] [--all] [--grep <正则>]
//     framework 默认 BatteryCenter PowerUI；--all=列出全部类（默认仅 /Charge|Power|Battery/ 过滤）
//     注意：PowerUI 框架加载在早期 JXA 迭代中曾触发 SIGSEGV——本工具逐框架独立输出，
//     崩溃时已打印的前序框架结果仍有效（崩溃本身=信息，如实记录）。
// 只读保证：dlopen + ObjC runtime 查询，无任何写操作；无守护进程/电量前置（E0 无门禁，照方案 §5）。

import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

var frameworks = ["BatteryCenter", "PowerUI"]
var all = false
var grep: String?

var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--all": all = true
    case "--grep": grep = args.first; if grep != nil { args.removeFirst() }
    default: frameworks = [a]
    }
}

let classPattern = all ? try! NSRegularExpression(pattern: ".") : try! NSRegularExpression(pattern: "Charge|Power|Battery")
let methodPattern = grep.map { try! NSRegularExpression(pattern: $0) }

func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
    let r = NSRange(s.startIndex..., in: s)
    return re.firstMatch(in: s, range: r) != nil
}

var totalClasses = 0
var printedClasses = 0
var totalMethods = 0

for fw in frameworks {
    let path = "/System/Library/PrivateFrameworks/\(fw).framework/\(fw)"
    let handle = dlopen(path, RTLD_LAZY)
    if handle == nil {
        print("## framework=\(fw) dlopen=nil（\(String(cString: dlerror()))）——如实记录")
        continue
    }
    print("## framework=\(fw) dlopen=ok")
    // objc_copyClassNamesForImage 需要精确的已注册镜像路径——经 dyld 镜像表反查（框架内含 Versions 层级，传入路径常不匹配）
    var imagePath = path
    for i in 0..<_dyld_image_count() {
        if let p = _dyld_get_image_name(i) {
            let s = String(cString: p)
            if s.contains("\(fw).framework") { imagePath = s; break }
        }
    }
    print("## framework=\(fw) registeredImage=\(imagePath)")
    var count: UInt32 = 0
    guard let names = objc_copyClassNamesForImage(imagePath, &count) else {
        print("## framework=\(fw) 类名枚举=nil（image=\(imagePath)）")
        continue
    }
    totalClasses += Int(count)
    print("## framework=\(fw) classes=\(count)")
    for i in 0..<Int(count) {
        let name = String(cString: names[i])
        guard matches(classPattern, name) else { continue }
        guard let anyCls = objc_getClass(name), let cls = anyCls as? AnyClass else { continue }
        printedClasses += 1
        var mcount: UInt32 = 0
        let methods = class_copyMethodList(cls, &mcount)
        var lines: [String] = []
        if methods != nil {
            for j in 0..<Int(mcount) {
                let selNamePtr = sel_getName(method_getName(methods![j]))
                let sel = String(cString: selNamePtr)
                totalMethods += 1
                let encPtr = method_getTypeEncoding(methods![j])
                let enc = (encPtr != nil) ? String(cString: encPtr!) : "?"
                if let g = methodPattern, !matches(g, sel) { continue }
                lines.append("  \(sel)  \(enc)")
            }
            free(methods)
        }
        print("## class=\(name) instanceMethods=\(mcount)")
        for l in lines { print(l) }
        // 类方法（元类）枚举——实例化入口（sharedClient 等 accessor）在此
        if let metaMethods = class_copyMethodList(object_getClass(cls), &mcount) {
            var metaLines: [String] = []
            for j in 0..<Int(mcount) {
                let selNamePtr = sel_getName(method_getName(metaMethods[j]))
                let sel = String(cString: selNamePtr)
                let encPtr = method_getTypeEncoding(metaMethods[j])
                let enc = (encPtr != nil) ? String(cString: encPtr!) : "?"
                if let g = methodPattern, !matches(g, sel) { continue }
                metaLines.append("  + \(sel)  \(enc)")
            }
            free(metaMethods)
            if !metaLines.isEmpty {
                print("## class=\(name) classMethods=\(mcount)")
                for l in metaLines { print(l) }
            }
        }
    }
    free(names)
}

print("## total.imagesClasses=\(totalClasses) printedClasses=\(printedClasses) totalInstanceMethods=\(totalMethods)")
print("## verdict=done（只读枚举完成——命中 setter 候选请带入 spike-ga-jxa.js CANDIDATE/SETTER 列表）")
