// CellarCoreCheck —— 0.23.21-alpha 整理批 ProfileDomain 拆分：九个纯源码读取
// 钉块（源钉-1/2/3/3b/4/5/7/8/10——0.23.20 评审二轮逐块实证无 fixture 依赖）
// 迁本文件独立 runner；ProfileDomain.swift 留守判定面（方案-1..14 + 随批-1..2）
// + 源钉-9（行为面三断言 + capturedProfile/base fixture）。源钉-8 跨块依赖
// 源钉-5/4 局部 src 变量（statsTrendSrc/sectionViewSrc）随块同迁——双 runner
// Main.main 双注册，场景总数相加不减（拆分静默丢失防线：源钉-10 注册行反钉）。
//
// 全部源文件读取（Data 注入仓库相对路径），零渲染、零进程。

import CellarCore
import Foundation

/// 0.23.21-alpha 整理批 Profile 源钉场景域入口（Main.main 调用——与
/// runProfileDomainScenarios 双注册，场景总数相加不减）。
func runProfileDomainPinsScenarios() {

    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            check(false, "Profile-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    // 源钉-1：AppConfig 双字段 decode/encodeIfPresent 在位。
    let appSideSrc = source("Sources/CellarCore/Daemon/AppSide.swift")
    check(appSideSrc.contains("case profiles")
              && appSideSrc.contains("case activeProfileID")
              && appSideSrc.contains("profiles = try container.decodeIfPresent([ProfilePayload].self, forKey: .profiles)")
              && appSideSrc.contains("activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID)")
              && appSideSrc.contains("try container.encodeIfPresent(profiles, forKey: .profiles)")
              && appSideSrc.contains("try container.encodeIfPresent(activeProfileID, forKey: .activeProfileID)"),
          "源钉-1", "AppConfig 双字段四位同步（CodingKeys + decodeIfPresent ×2 + encodeIfPresent ×2——nil 缺席零键增量）")

    // 源钉-2：runControl 三改造（internal widening + String? 反馈 + onFailure 钩子）。
    let statusControllerSrc = source("App/CellarApp/StatusController.swift")
    check(statusControllerSrc.contains("    func runControl(")
              && !statusControllerSrc.contains("private func runControl("),
          "源钉-2", "runControl private → internal（链扩展文件驱动单槽通道——R2 P1-A widening 先例）")
    check(statusControllerSrc.contains("let successFeedback: String?")
              && statusControllerSrc.contains("successFeedback: String?,")
              && statusControllerSrc.contains("if let feedback = successFeedback {"),
          "源钉-2", "successFeedback String?（QueuedControlCall + runControl 形参 + finishControl nil 分支单点 if let——链步静默仅链尾聚合）")
    check(statusControllerSrc.contains("onFailure: (@MainActor (DaemonClientError) -> Void)? = nil")
              && statusControllerSrc.contains("onFailure: (@MainActor (DaemonClientError) -> Void)?,")
              && statusControllerSrc.contains("onFailure?(error)")
              && statusControllerSrc.contains("onFailure: queued.onFailure,"),
          "源钉-2", "onFailure 钩子（默认 nil 参数 + finishControl 形参 + 失败分支 classifyControlFailure 之后调用 + 队列补发透传）")
    check(statusControllerSrc.contains("profile 链扩展文件")
              && statusControllerSrc.contains("横幅串击")
              && statusControllerSrc.contains("失败链残留非 nil 状态"),
          "源钉-2", "WHY 三条齐（internal widening / String? 串击 / onFailure 清链落点——评审 P1-2）")
    check(statusControllerSrc.contains("ProfileController.shared.maybeCaptureDefault(status)"),
          "源钉-2", "ingest 尾部迁移挂点（首启静默捕获——幂等单发守卫在 ProfileController）")
    check(statusControllerSrc.contains("var profileChain: ProfileChainState?"),
          "源钉-2", "链状态存储槽在主类（extension 无存储属性——LED internal setter 同款先例）")

    // 源钉-3：编排器面（链存续守卫/守卫二发起前/每步重推导/穷举映射/补偿/nil 反馈/清链/fan 注记）。
    let profileApplySrc = source("App/CellarApp/StatusController+ProfileApply.swift")
    let advanceSegment = profileApplySrc.components(
        separatedBy: "private func advanceProfileChain").dropFirst().first ?? ""
    check(advanceSegment.contains("guard let chain = profileChain else { return }")
              && advanceSegment.range(of: "guard let chain = profileChain")?.lowerBound
                  ?? advanceSegment.startIndex
                  < advanceSegment.range(of: "chainGuardShouldAbort")?.lowerBound ?? advanceSegment.endIndex,
          "源钉-3", "链存续守卫入口判定（guard let chain 先于一切链状态访问——评审 P1 时序防御）")
    check(advanceSegment.contains("ProfileModel.applyPlan(profile: chain.payload, current: status)")
              && advanceSegment.contains("ProfileModel.chainGuardShouldAbort(")
              && advanceSegment.range(of: "ProfileModel.applyPlan")?.lowerBound
                  ?? advanceSegment.startIndex
                  < advanceSegment.range(of: "ProfileModel.chainGuardShouldAbort")?.lowerBound ?? advanceSegment.endIndex,
          "源钉-3", "每步重推导（applyPlan 在 advance 内——评审 P2-2）+ 守卫经 ProfileModel.chainGuardShouldAbort 纯函数 + 守卫单点在重推导之后（评审收口 P1 次序）")
    check(profileApplySrc.contains("case .setLimits(let upperLimit, let hysteresis):")
              && profileApplySrc.contains("case .setFan(let wire):")
              && profileApplySrc.contains("case .setThermal(let wire):")
              && profileApplySrc.contains("case .setChargeSchedule(let json):")
              && profileApplySrc.contains("case .setCalibrationSchedule(let wire):")
              && profileApplySrc.contains("case .setChHysteresisEnabled(let enabled):")
              && profileApplySrc.contains("case .disable:")
              && profileApplySrc.contains("case .setMagSafeLed(let raw):"),
          "源钉-3", "编排器 exhaustive switch 八 case（新增 case 编译期强制同步）")
    check(profileApplySrc.components(separatedBy: "successFeedback: nil,").count - 1 == 8,
          "源钉-3", "链步成功反馈 nil 恰八处（横幅串击根除——B3-4，仅链尾 control.profile.applied 聚合）")
    check(profileApplySrc.components(separatedBy: "onFailure: { _ in self.profileChain = nil }").count - 1 == 8,
          "源钉-3", "onFailure 清链恰八处（失败即停——评审 P1-2）")
    check(profileApplySrc.contains("self.reconcileShutdownResidualNow()")
              && profileApplySrc.contains("advanceProfileChain(from: status)"),
          "源钉-3", ".disable 步补偿（toggleCharging(false) 同款 reconcileShutdownResidualNow——LimitExecution:56 internal 零改动）+ onSuccess 续链")
    check(profileApplySrc.contains("field: .strategy 取形注记")
              && profileApplySrc.contains(".setFan(wire, .strategy)")
              && profileApplySrc.contains("guard let mode = MagSafeLEDMode(rawValue: raw)"),
          "源钉-3", "fan 步 field 取形注记 + .strategy 取值 + LED raw 白名单防御（非法 raw 永不收敛 → abortChain）")

    // 源钉-3b：ControlModels `.setMagSafeLed` case 恢复（双臂 + 隔离偏离登记）。
    let controlModelsSrc = source("App/CellarApp/ControlModels.swift")
    check(controlModelsSrc.contains("case setMagSafeLed(MagSafeLEDMode)")
              && controlModelsSrc.contains("status.summary.setMagSafeLed")
              && controlModelsSrc.contains("两通道并存、互不渗透"),
          "源钉-3b", "ControlAttempt .setMagSafeLed case 恢复 + summary 臂（status.summary.setMagSafeLed 键已在 catalog 零增量）+ 轻路径隔离偏离登记注记")
    check(statusControllerSrc.contains("applyLedStepDirect(mode)")
              && profileApplySrc.contains("func applyLedStepDirect(_ mode: MagSafeLEDMode)")
              && profileApplySrc.contains("attempt: .setMagSafeLed(mode)"),
          "源钉-3b", "retryLastAttempt 臂经 applyLedStepDirect 单步重发（回 runControl 同一通道——不照抄旧轻路径臂；成功反馈复用 status.summary.setMagSafeLed 键）")

    // 源钉-7：catalog 新键逐字直读 + 键数精确断言（commit 2 后 491+16=507）。
    let catalogURL = repoRoot.appendingPathComponent("Sources/CellarUI/Resources/Localizable.xcstrings")
    if let data = try? Data(contentsOf: catalogURL),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let strings = root["strings"] as? [String: Any] {
        check(strings.count == 513,
              "源钉-7", "catalog 键数精确断言 513（491 + 16 profile 键 = 507〔commit 2〕+ 5 − 1 = 511〔commit 4：versionLine3/handshake 三键/btmDrift 入库、versionLine 退役〕+ 2 = 513〔0.23.22 commit 2：panel.daemon.stalePin/reRegister 两键入库——stale-pin 精确行 + 一键重注册〕——断言值随批推进）")
        let expectations: [String: String] = [
            "control.profile.title": "充电方案",
            "control.profile.empty": "暂无方案。从当前设置创建第一个方案。",
            "control.profile.duplicateSuffix": "%@ 副本",
            "control.profile.defaultName": "默认",
            "control.profile.deleteConfirm": "确认删除「%@」？",
            "control.profile.nameInvalid": "名称不能为空且不超过 40 个字符",
            "control.profile.captureUnavailable": "无法捕获当前设置（守护进程版本过旧）",
            "control.profile.limitReached": "方案数已达上限（%lld）",
            "control.profile.applied": "已应用方案「%@」",
            "control.profile.notConverged": "方案「%@」中止：守护进程读回未收敛，已停止切换",
            "panel.menu.profiles": "充电方案",
            "panel.versionLine3": "守护进程 %1$@（协议兼容）· App %2$@ · %3$@",
        ]
        var allPresent = true
        for (key, zh) in expectations {
            func localized(_ locale: String) -> String? {
                if let entry = strings[key] as? [String: Any],
                   let localizations = entry["localizations"] as? [String: Any],
                   let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any] {
                    return unit["value"] as? String
                }
                return nil
            }
            if localized("zh-Hans") != zh || localized("en") == nil || localized("en")?.isEmpty == true {
                allPresent = false
            }
        }
        check(allPresent, "源钉-7", "catalog 新键逐字直读（zh-Hans 抽样 12 键逐字 + en 双语齐——extractionState manual 单一门面）")
        // 0.23.19 热修：versionLine3 双语新词面逐字（0.23.18 用户第 4 次误读——
        // 「协议兼容」括注紧跟 daemon 版本，双数字并排的「落后/不一致」歧义消除；
        // 位置参数 %1$@/%2$@/%3$@ 形态保留、after 字面无「握手」——「握手」由
        // 第三参词串 panel.handshake.connected 自带，防「握手握手正常」缺陷串）。
        func unit(_ key: String, _ locale: String) -> String? {
            if let entry = strings[key] as? [String: Any],
               let localizations = entry["localizations"] as? [String: Any],
               let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any] {
                return unit["value"] as? String
            }
            return nil
        }
        check(unit("panel.versionLine3", "zh-Hans") == "守护进程 %1$@（协议兼容）· App %2$@ · %3$@"
                  && unit("panel.versionLine3", "en") == "Daemon %1$@ (protocol compatible) · App %2$@ · %3$@",
              "源钉-7", "versionLine3 双语新词面逐字（位置参数三形态保留 + 无「握手」前缀——零新键，ControlSectionView 消费零改动）")
    } else {
        check(false, "源钉-7", "catalog 键结构缺席（双语源钉红）")
    }

    // ---- 源钉-4：菜单组装 + 管理页接入源钉（源文件读取）----

    let statusItemSrc3 = source("App/CellarApp/StatusItemController.swift")
    check(statusItemSrc3.contains("MenuProfileModel.items(")
              && statusItemSrc3.contains("profiles: ProfileController.shared.profiles,")
              && statusItemSrc3.contains("status: controller.daemonStatus,")
              && statusItemSrc3.contains("busy: controller.busy,")
              && statusItemSrc3.contains("actionActive: controller.action != nil"),
          "源钉-4", "菜单组装 items(status:) 直入四参（模型内派生 ✓——意图镜像无通路）")
    check(statusItemSrc3.contains("if !profileItems.isEmpty {")
              && statusItemSrc3.contains("item.representedObject = profileItem.id")
              && statusItemSrc3.contains("item.state = profileItem.isSelected ? .on : .off")
              && statusItemSrc3.contains("item.isEnabled = profileItem.enabled")
              && statusItemSrc3.contains("#selector(applyProfileClicked(_:))")
              && statusItemSrc3.contains("sender.representedObject as? String"),
          "源钉-4", "菜单 profile 区（空整区省略 / representedObject = id / state .on 读回命中 / applyProfileClicked id→payload→switchTo）")
    let menuPresetSrc = source("Sources/CellarCore/Control/MenuPresetModel.swift")
    check(menuPresetSrc.contains("case quickLimit")
              && !menuPresetSrc.contains("case profile"),
          "源钉-4", "MenuPresetModel.Section 不扩 enum（profile 项独立模型独立数组——对调研 B4 的偏离钉死）")
    let controlPageSrc = source("App/CellarApp/ControlPageView.swift")
    let controlRange = controlPageSrc.range(of: "ControlSectionView()")
    let profileRange = controlPageSrc.range(of: "ProfileSectionView()")
    let actionRange = controlPageSrc.range(of: "ActionSectionView()")
    check(controlRange != nil && profileRange != nil && actionRange != nil
              && controlRange!.lowerBound < profileRange!.lowerBound
              && profileRange!.lowerBound < actionRange!.lowerBound,
          "源钉-4", "ControlPageView 接入序（ControlSectionView → ProfileSectionView → ActionSectionView——整包控制居单旋钮控制与一次性动作之间）")
    let panelViewSrc3 = source("App/CellarApp/PanelView.swift")
    check(!panelViewSrc3.contains("ProfileSectionView"),
          "源钉-4", "面板 PanelView 零改动（profile 节仅主窗充电控制页——方案 §2.5）")
    let sectionViewSrc = source("App/CellarApp/ProfileSectionView.swift")
    // 0.23.21-alpha 整理批改钉（isActive 单次求值上提联动——原字面串
    // 「ProfileModel.activeMatch(profiles: profileController.profiles,
    // current: current) == profile.id」随上提消失）：钉新形态「body 内单次求值
    // + activeID == profile.id 比较」+ 老逐行函数退役反钉（语义逐点等价——
    // 同一纯函数同一输入；失联 nil 全不点亮不变）。
    check(sectionViewSrc.contains("let activeID = statusController.daemonStatus.flatMap {")
              && sectionViewSrc.contains("ProfileModel.activeMatch(profiles: profileController.profiles, current: $0)")
              && sectionViewSrc.contains("activeID == profile.id")
              && !sectionViewSrc.contains("func isActive(")
              && sectionViewSrc.contains("@ObservedObject private var profileController = ProfileController.shared")
              && sectionViewSrc.contains("ProfileModel.isValidName(renameDraft)")
              && sectionViewSrc.contains("control.profile.nameInvalid")
              && sectionViewSrc.contains("deletePendingID = profile.id")
              && sectionViewSrc.contains("control.profile.empty")
              && sectionViewSrc.contains("ProfileModel.capture(from: status) != nil"),
          "源钉-4", "管理页面（✓ activeMatch 读回派生单次求值 activeID 比较——0.23.21 isActive 上提 O(n²)→O(n)，老函数退役反钉 / ProfileController.shared 直注非第七注入 / 行内红字命名校验 / 删除两步确认 / 空态引导 / 新建 capture 预检逐项）")

    // ---- 源钉-5：三随批消费面（版本行三口径 + btmDrift 行 + versionLine 退役）----

    let controlSectionSrc = source("App/CellarApp/ControlSectionView.swift")
    check(controlSectionSrc.contains("\"panel.versionLine3\"")
              && !controlSectionSrc.contains("\"panel.versionLine\",")
              && controlSectionSrc.contains("Bundle.main.object(forInfoDictionaryKey: \"CFBundleShortVersionString\")")
              && controlSectionSrc.contains("handshakeWord(statusController.connection)")
              && controlSectionSrc.contains("case .connected: return CellarL10n.s(\"panel.handshake.connected\")")
              && controlSectionSrc.contains("case .unreachable: return CellarL10n.s(\"panel.handshake.unreachable\")")
              && controlSectionSrc.contains("case .unknown: return CellarL10n.s(\"panel.handshake.unknown\")"),
          "源钉-5", "版本行三口径消费（versionLine3 三参 / App 串 = Bundle CFBundleShortVersionString / 握手词 = connection 三态映射经 l10n——versionLine 两口径退役）")
    let daemonSectionSrc = source("App/CellarApp/DaemonSectionView.swift")
    check(daemonSectionSrc.contains("btmAnchorDriftSuspected(")
              && daemonSectionSrc.contains("registration: installer.registration,")
              && daemonSectionSrc.contains("route: installer.route,")
              && daemonSectionSrc.contains("connection: statusController.connection")
              && daemonSectionSrc.contains("\"panel.daemon.btmDrift\""),
          "源钉-5", "DaemonSectionView btmDrift 疑似行（btmCorrupted 行后同形态——registration/route/connection 三输入接线）")
    let registrationSrc = source("Sources/CellarCore/Daemon/DaemonRegistration.swift")
    check(registrationSrc.contains("public func btmAnchorDriftSuspected(")
              && registrationSrc.contains("registration == .enabled && route == .unknown && connection == .unreachable"),
          "源钉-5", "btmAnchorDriftSuspected 纯函数落 DaemonRegistration.swift（AppSide 445 行超 400 软限——按 400 行限择位）")
    let catalogSrc = source("Sources/CellarUI/Resources/Localizable.xcstrings")
    check(!catalogSrc.contains("\"panel.versionLine\"")
              && catalogSrc.contains("\"panel.versionLine3\"")
              && catalogSrc.contains("\"panel.handshake.connected\"")
              && catalogSrc.contains("\"panel.handshake.unknown\"")
              && catalogSrc.contains("\"panel.daemon.btmDrift\""),
          "源钉-5", "catalog versionLine 键退役 + 四新键在位（净 +4：507 → 511——R9 隐藏消费者 grep 全仓实证唯一后退役）")
    let statsTrendSrc = source("Sources/CellarCore/Stats/StatsTrend.swift")
    check(!statsTrendSrc.contains("DateFormatter()")
              && statsTrendSrc.contains("String(format: \"%04d-%02d-%02d\", year, month, day)")
              && statsTrendSrc.components(separatedBy: "String(format: \"%04d-%02d-%02d\", year, month, day)").count - 1 == 2,
          "源钉-5", "StatsTrend DateFormatter 退役（dayString/dayStringFromOrdinal 双函数 dateComponents 派生恰二处——输出逐字节等价，统计40-63 既有场景即回归门）")

    // ---- 源钉-8：评审收口（全审 1 P1 + 1 P2 + 2 P3 修正面源钉）----

    // P1：链尾判定前置——plan.first 判空先于守卫判定（防「守卫二先行误杀满序链
    // 收敛尾」回归）；nextStep: nil 双语义入口退役反钉。
    let profileApplySrc2 = source("App/CellarApp/StatusController+ProfileApply.swift")
    let advanceSegment2 = profileApplySrc2.components(
        separatedBy: "private func advanceProfileChain").dropFirst().first ?? ""
    let planFirstRange = advanceSegment2.range(of: "guard let step = plan.first else {")
    let finishRange = advanceSegment2.range(of: "finishProfileChain()")
    let guardRange = advanceSegment2.range(of: "ProfileModel.chainGuardShouldAbort(")
    check(planFirstRange != nil && finishRange != nil && guardRange != nil
              && planFirstRange!.lowerBound < guardRange!.lowerBound
              && finishRange!.lowerBound < guardRange!.lowerBound,
          "源钉-8", "P1 链尾判定前置（plan.first 判空 + finishProfileChain 先于收敛守卫——八步满序链 executed=8 回包经链尾 finish 不被守卫二误杀；守卫单点仍发步前）")
    check(!advanceSegment2.contains("nextStep: nil, executed:")
              && profileApplySrc2.contains("nextStep: step, executed: chain.executed"),
          "源钉-8", "P1 nextStep: nil 双语义入口退役反钉（唯一调用形态 nextStep: step——chainGuardShouldAbort 签名收窄非可选单语义）")
    let profileModelSrc = source("Sources/CellarCore/Control/ProfileModel.swift")
    check(profileModelSrc.contains("nextStep: ProfileApplyStep,")
              && !profileModelSrc.contains("nextStep: ProfileApplyStep?,\n        executed: Int\n    ) -> Bool {\n        if executed >="),
          "源钉-8", "P1 纯函数签名收窄（nextStep 非可选单语义——lastStep == nextStep ∨ executed ≥ applyStepCaseCount）")
    // P2：dayString 历法恒公历（非公历系统历法用户日键分裂防线）。
    check(statsTrendSrc.contains("var gregorian = Calendar(identifier: .gregorian)")
              && statsTrendSrc.contains("gregorian.timeZone = calendar.timeZone")
              && statsTrendSrc.components(separatedBy: "Calendar(identifier: .gregorian)").count - 1 == 2,
          "源钉-8", "P2 dayString 历法恒公历（传入日历仅取时区——佛教历/和历系统用户输出与旧 DateFormatter(en_US_POSIX) 逐字节等价恢复；.gregorian 恰二处：dayString + utcCalendar）")
    // P2 行为面：非公历传入日历注入直测——输出仍公历形态（等价性非仅源钉）。
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
    var gregorianProbe = Calendar(identifier: .gregorian)
    gregorianProbe.timeZone = TimeZone(identifier: "Asia/Bangkok")!
    let probeDate = gregorianProbe.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
    check(DailyHealthRollup.dayString(for: probeDate, calendar: buddhist) == "2026-11-11",
          "源钉-8", "P2 行为面：佛教历传入日历注入 → 输出仍公历 2026-11-11（2570 形态根除——旧 DateFormatter(en_US_POSIX) 等价恢复直测）")
    // P3：管理页行禁用视觉（三门命中行透明度——CRUD 三钮功能保持）。
    check(sectionViewSrc.contains("switchDisabled")
              && sectionViewSrc.contains(".opacity(switchDisabled ?"),
          "源钉-8", "P3 管理页行禁用视觉（switchDisabled 三门共源 + 行条件透明度——busy 置灰先例形态，CRUD 三钮不动作保持）")

    // ---- 源钉-10：0.23.20 热修 schedule 语义比较（public 纯函数 + applyPlan/
    // scheduleFieldMatches 双消费点 + capture 归一在位 + ABORT 双原串打点键名 +
    // 256/256+len 截断形态）----

    let profileModelSrc3 = source("Sources/CellarCore/Control/ProfileModel.swift")
    check(profileModelSrc3.contains("public static func scheduleSemanticallyEqual(_ lhs: String?, _ rhs: String?) -> Bool"),
          "源钉-10", "scheduleSemanticallyEqual public 纯函数（消费方跨模块——public 非 internal，matchReport/applyPlan 先例同形态）")
    check(profileModelSrc3.contains("if let json = profile.scheduleJson,\n           !scheduleSemanticallyEqual(profile.scheduleJson, current.scheduleJson) {"),
          "源钉-10", "applyPlan 消费点（if let json 绑定保留——步载荷需非可选 json 禁强解包；仅条件换语义比较）")
    check(profileModelSrc3.contains("return scheduleSemanticallyEqual(json, status.scheduleJson)"),
          "源钉-10", "scheduleFieldMatches 消费点（readbackMatches 的 schedule 域 → 语义比较——判定域 byte 形态退役）")
    check(profileModelSrc3.contains("ChargeScheduleConfig.decoded(from: scheduleJson)")
              && profileModelSrc3.contains("normalizedSchedule = decoded.encoded ?? scheduleJson")
              && profileModelSrc3.contains("normalizedSchedule = scheduleJson"),
          "源钉-10", "capture 归一在位（decoded 成功 → encoded ?? 原串；解码失败原样存——归一内联 capture 不新增 private helper）")
    check(profileModelSrc3.components(separatedBy: "private static func").count - 1 == 11,
          "源钉-10", "private static func 恰 11 反钉（scheduleSemanticallyEqual public + 归一内联——既有 helper 计数原数不变）")
    let profileApplySrc4 = source("App/CellarApp/StatusController+ProfileApply.swift")
    check(profileApplySrc4.contains("schedRaw=") && profileApplySrc4.contains("expected="),
          "源钉-10", "ABORT 行双原串打点键名（schedRaw= 方案侧 / expected= 现值侧——防与 match 段 sched= 布尔撞名）")
    check(profileApplySrc4.contains("private static func forensicTruncated(_ raw: String?) -> String")
              && profileApplySrc4.contains("raw.utf8.prefix(256)")
              && profileApplySrc4.contains("raw.utf8.suffix(256)")
              && profileApplySrc4.contains("byteCount > 512")
              && profileApplySrc4.contains("(len=\\(byteCount))"),
          "源钉-10", "截断策略形态（head 256 + tail 256 字节 + 总长标注——超 512 拼 head…tail (len=N)；单插值 helper 返回完整串，privacy 计数恰 33 依赖此形态）")
    check(profileApplySrc4.components(separatedBy: "Self.forensicTruncated(").count - 1 == 2,
          "源钉-10", "双原串各恰一插值（payload.scheduleJson + status.scheduleJson——拆三插值则 privacy 35，计数钉强制对齐）")
    // 0.23.21-alpha 整理批增注册行反钉（本文件落位）：Main.main 双注册在位——
    // 拆分文件静默丢失防线（0.23.20 评审 P1 实证的缺失面）。
    let mainEntrySrc = source("Sources/CellarCoreCheck/MainEntry.swift")
    check(mainEntrySrc.contains("runProfileDomainPinsScenarios()"),
          "源钉-10", "注册行反钉（MainEntry.swift 源码 contains runProfileDomainPinsScenarios()——新 runner 未注册即红）")
}
