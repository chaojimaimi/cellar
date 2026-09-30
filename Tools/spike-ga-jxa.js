#!/usr/bin/env osascript -l JavaScript
// Cellar macOS 27 GA JXA PowerUISmartChargeClient spike（S3）— 方案 docs/plans/phase5-0.20-macos27-ga-spike.md §5 v3 定稿
// 运行：osascript -l JavaScript Tools/spike-ga-jxa.js probe [--skip 名1,名2] | set <n> | restore [n]
// E0 是发现性步骤（允许多轮迭代）：枚举候选私有框架 → NSBundle 加载 → objc_getClass 解析类 →
//   方法表计数 + 候选 selector 逐个探针（存在性 + 签名）；失败时输出可诊断信息，只读。
// set <n>：调用 setMCLLimit 或探针命中的等价 setter；<80 的 segfault 预期（PR #480）由 .sh 包装在独立子进程捕获。
// restore：设回 100 或提示系统设置 UI 兜底（R7：UI 是 PowerUIAgent 正门）。
//
// 实测定版机制（本机 osascript JXA，2026-09-26 探针验证；后续迭代不得回退这些坑）：
//   1. ObjC.import('私有框架') 多半 "nothing found to import" —— 必须走 NSBundle.bundleWithPath().loadAndReturnError
//   2. bindFunction 类型名须全称 'unsigned int'（'uint' 静默段错误、'ulong' NSException）
//   3. JXA Class 包装对象不能当 'pointer' 传参——类指针必须经 objc_getClass(名字) 裸取
//   4. 类活性判定 = class_getName(裸指针) === 类名（缺失时返回 'nil'）
//   5. 方法指针数组（class_copyMethodList 返回）按 8 字节元素但在 arm64e 上地址 >2^53，
//      JS Number 精度不足 + 桥接 'string' 返回遇 NULL 抛不可 catch 的 NSException——
//      全量枚举不可行，改「方法表计数（表存在性证据）+ 候选 selector 逐个探针（纯 ObjC 桥判存在性）」
//   6. JS 数组桥接 NSMutableArray：push(nil) 即 NSException——一切桥接返回先判空

ObjC.import("Foundation");

// 候选面（调研 §8 + PR #480 线索 + 运行时探针为准——E0 发现性步骤，多轮迭代预注册）
var CANDIDATE_FRAMEWORKS = [
	"PowerUI",
	"BatteryCenter",
	"BatteryUI",
	"ChargingUI",
	"PowerUICore",
];
var CANDIDATE_CLASSES = [
	"PowerUISmartChargeClient",
	"PowerUIChargeLimitClient",
	"PowerUISmartChargingClient",
	"SmartChargeClient",
	"PowerUIBatteryClient",
	"PowerUIChargingController",
	"PowerUISmartChargeManager",
	"PowerUIChargeLimitController",
];
var SETTER_GUESSES = [
	"setMCLLimit:error:",
	"setMCLLimit:withHandler:",
	"setMCLLimit:",
	"setMCLLimitValue:",
	"setMCLimit:",
	"setChargeLimit:",
	"setLimit:",
	"setSocLimit:",
	"setChargeLimitOverride:",
	"setManualChargeLimit:",
	"setDesiredChargeLimit:",
	"updateChargeLimit:",
	"setMclLimitValue:",
	"setMclLimit:",
	"setMCLFeatureState:",
	"setMclFeatureState:",
	"setChargeSocLimit:",
	"setSocLimitOverride:",
	"setMaxChargeLimit:",
	"applyChargeLimit:",
	"requestChargeLimit:",
];
var GETTER_GUESSES = [
	"getMCLLimitWithError:",
	"isMCLSupported",
	"isMCLCurrentlyEnabled:",
	"currentChargeLimit:",
];
var SETTER_GETTER_PAIRS = [
	["setMCLLimit:", "mclLimit"],
	["setMCLLimitValue:", "mclLimitValue"],
	["setChargeLimit:", "chargeLimit"],
	["setSocLimit:", "socLimit"],
	["setManualChargeLimit:", "manualChargeLimit"],
	["setLimit:", "limit"],
	["setMclLimitValue:", "mclLimitValue"],
	["setMclLimit:", "mclLimit"],
	["setChargeSocLimit:", "chargeSocLimit"],
];
var ACCESSOR_GUESSES = [
	"sharedClient",
	"standardClient",
	"defaultClient",
	"currentClient",
	"shared",
	"client",
];

var OUT = [];
var SKIP = {}; // --skip 名1,名2：跳过已证实会 segfault 的框架加载（E0 多轮迭代机制）
function say(s) {
	OUT.push(s);
	console.log(s); // 增量流式到 stderr：候选框架加载 segfault（进程级崩溃不可捕获）时，进度与元凶仍可追溯
}
function kv(k, v) {
	say(k + "=" + v);
} // 机器可读 marker 行（.sh 包装解析）

// ── 框架枚举（只读）────────────────────────────────────────────────
function listPrivateFrameworks(pattern) {
	var fm = $.NSFileManager.defaultManager;
	var err = Ref();
	var items = fm.contentsOfDirectoryAtPathError(
		"/System/Library/PrivateFrameworks",
		err,
	);
	if (items.isNil()) {
		return [];
	}
	var n = items.count;
	var out = [];
	for (var i = 0; i < n; i++) {
		var name = ObjC.unwrap(items.objectAtIndex(i));
		if (pattern.test(name)) {
			out.push(name);
		}
	}
	return out;
}

function frameworkExists(name) {
	return $.NSFileManager.defaultManager.fileExistsAtPath(
		"/System/Library/PrivateFrameworks/" + name + ".framework",
	);
}

// 框架加载：NSBundle load（ObjC.import 对私有框架失效——"nothing found to import"）。
// 加载把二进制 dlopen 进进程，Objective-C 类随之注册进运行时，objc_getClass 才能解析。
function loadFrameworkBundle(name) {
	try {
		var path = "/System/Library/PrivateFrameworks/" + name + ".framework";
		var bundle = $.NSBundle.bundleWithPath(path);
		if (bundle.isNil()) {
			return "bundle-not-found";
		}
		var errRef = Ref();
		var loaded = bundle.loadAndReturnError(errRef);
		return loaded ? "ok" : "load-returned-false";
	} catch (e) {
		return "failed: " + e.message;
	}
}

// ── ObjC runtime 绑定（C 函数；类型名全称；标量指针，无数组索引）──────
var runtimeBound = false;
function bindRuntime() {
	if (runtimeBound) {
		return true;
	}
	try {
		ObjC.bindFunction("objc_getClass", ["pointer", ["string"]]);
		ObjC.bindFunction("class_getName", ["string", ["pointer"]]);
		ObjC.bindFunction("object_getClass", ["pointer", ["pointer"]]);
		ObjC.bindFunction("class_copyMethodList", [
			"pointer",
			["pointer", "pointer"],
		]);
		ObjC.bindFunction("sel_registerName", ["pointer", ["string"]]);
		ObjC.bindFunction("class_getInstanceMethod", [
			"pointer",
			["pointer", "pointer"],
		]);
		ObjC.bindFunction("class_getClassMethod", [
			"pointer",
			["pointer", "pointer"],
		]);
		ObjC.bindFunction("method_getNumberOfArguments", [
			"unsigned int",
			["pointer"],
		]);
		ObjC.bindFunction("method_copyReturnType", ["string", ["pointer"]]);
		ObjC.bindFunction("method_copyArgumentType", [
			"string",
			["pointer", "unsigned int"],
		]);
		runtimeBound = true;
		return true;
	} catch (e) {
		kv("probe.bindFunction", "failed: " + e.message);
		return false;
	}
}

function safeStr(v) {
	return v === null || typeof v === "undefined" ? "?" : String(v);
}

/// 方法表计数（表存在性证据；全量枚举受 JXA 指针精度限制不可行——见文件头实测注记 5）
function countMethods(classPtr) {
	if (!classPtr) {
		return -1;
	}
	try {
		var countRef = Ref("unsigned int"); // 类型名 'unsigned int' 全称（实测定版）
		$.class_copyMethodList(classPtr, countRef);
		var n = countRef[0];
		return n > 4096 ? -1 : n;
	} catch (e) {
		return -1;
	}
}

/// 候选 selector 探针：存在性走纯 ObjC 桥（NULL 安全）；签名只在确认存在后走 C 绑定（非 NULL 安全）
/// 2026-09-29 定版：SEL 必须含完整冒号（含尾冒号；无参方法无冒号）——此前剥尾冒号是 22 连空的可能真因。
function probeSelector(clsWrapper, rawCls, selName, isClassMethod) {
	try {
		var sel = selName;
		var stripped = selName.replace(/:$/, "");
		var candidates = stripped !== selName ? [selName, stripped] : [selName];
		var exists = null;
		for (var ci = 0; ci < candidates.length; ci++) {
			try {
				exists = isClassMethod
					? clsWrapper.respondsToSelector(candidates[ci])
					: clsWrapper.instancesRespondToSelector(candidates[ci]);
				if (exists) {
					sel = candidates[ci];
					break;
				}
			} catch (eInner) {
				exists = null;
			}
		}
		if (!exists) {
			return null;
		}
		var sig = "?";
		if (bindRuntime()) {
			try {
				var selPtr = $.sel_registerName(selName);
				var m = isClassMethod
					? $.class_getClassMethod(rawCls, selPtr)
					: $.class_getInstanceMethod(rawCls, selPtr);
				if (m) {
					var argc = $.method_getNumberOfArguments(m);
					var args = [];
					for (var a = 2; a < argc; a++) {
						var at = $.method_copyArgumentType(m, a);
						args.push(safeStr(at));
					}
					sig =
						"ret=" +
						safeStr($.method_copyReturnType(m)) +
						" args=[" +
						args.join(", ") +
						"]";
				}
			} catch (e2) {
				sig = "sig-failed: " + e2.message;
			}
		}
		return sig;
	} catch (e) {
		return "probe-failed: " + e.message;
	}
}

function findClass() {
	if (!bindRuntime()) {
		return null;
	}
	for (var i = 0; i < CANDIDATE_CLASSES.length; i++) {
		var name = CANDIDATE_CLASSES[i];
		var raw = $.objc_getClass(name);
		var liveName = raw ? safeStr($.class_getName(raw)) : "";
		if (liveName === name) {
			// class_getName 缺类返回 'nil'——按名字活性判定（实测定版）
			kv("probe.class_found", "yes");
			kv("probe.class", name);
			return { name: name, raw: raw, cls: $.NSClassFromString(name) };
		}
		kv("probe.class_try", name + ": not-found");
	}
	kv("probe.class_found", "no");
	return null;
}

function probe() {
	say("=== E0 探测（只读；发现性步骤，允许多轮迭代）===");
	var present = [];
	for (var i = 0; i < CANDIDATE_FRAMEWORKS.length; i++) {
		var fw = CANDIDATE_FRAMEWORKS[i];
		var ok = frameworkExists(fw);
		kv("probe.framework", fw + ": " + (ok ? "present" : "absent"));
		if (ok) {
			present.push(fw);
		}
	}
	// 宽枚举：私有框架目录中名称含 Power/Battery/Charge 的候选（诊断信息）
	kv(
		"probe.wideCandidates",
		listPrivateFrameworks(/(Power|Battery|Charge)/i).join(", "),
	);
	if (present.length === 0) {
		kv(
			"probe.verdict",
			"no-candidate-framework (把 wideCandidates 反馈给下一轮迭代)",
		);
		return;
	}
	for (var j = 0; j < present.length; j++) {
		if (SKIP[present[j]]) {
			kv("probe.load", present[j] + ": skipped(--skip 上轮 segfault 元凶)");
			continue;
		}
		try {
			ObjC.import(present[j]);
			kv("probe.import", present[j] + ": ok");
		} catch (e) {
			kv("probe.import", present[j] + ": failed: " + e.message);
		}
		kv("probe.bundleload", present[j] + ": " + loadFrameworkBundle(present[j]));
	}
	var found = findClass();
	if (!found) {
		kv(
			"probe.verdict",
			"class-not-resolved (诊断：框架已加载但类名不在候选集——把 wideCandidates + PR #480 线索对照下一轮)",
		);
		return;
	}
	// 方法表计数（实例 + 元类）——表存在性证据；全量枚举受 JXA 指针精度限制不可行
	var instCount = countMethods(found.raw);
	var meta = $.object_getClass(found.raw);
	var classCount = meta ? countMethods(meta) : -1;
	kv("probe.methodCount", String(instCount));
	kv("probe.classMethodCount", String(classCount));
	// 候选 selector 逐个探针（setter = 实例方法；accessor = 类方法）
	var hits = 0;
	for (var s = 0; s < SETTER_GUESSES.length; s++) {
		var sig = probeSelector(found.cls, found.raw, SETTER_GUESSES[s], false);
		if (sig !== null && sig.indexOf("probe-failed") !== 0) {
			hits++;
			kv("probe.instance." + SETTER_GUESSES[s], sig);
		}
		if (sig !== null && sig.indexOf("probe-failed") === 0) {
			kv("probe.instance." + SETTER_GUESSES[s], sig);
		}
	}
	for (var g = 0; g < SETTER_GETTER_PAIRS.length; g++) {
		var pair = SETTER_GETTER_GUESSES_SAFE(g);
		if (!pair) {
			continue;
		}
		var gs = probeSelector(found.cls, found.raw, pair, false);
		if (gs !== null && gs.indexOf("probe-failed") !== 0) {
			hits++;
			kv("probe.getter." + pair, gs);
		}
	}
	for (var gg = 0; gg < GETTER_GUESSES.length; gg++) {
		var gsel = GETTER_GUESSES[gg];
		var gsig = probeSelector(found.cls, found.raw, gsel, false);
		if (gsig !== null && gsig.indexOf("probe-failed") !== 0) {
			hits++;
			kv("probe.getter." + gsel, gsig);
		}
	}
	for (var a = 0; a < ACCESSOR_GUESSES.length; a++) {
		var as = probeSelector(found.cls, found.raw, ACCESSOR_GUESSES[a], true);
		if (as !== null && as.indexOf("probe-failed") !== 0) {
			hits++;
			kv("probe.classaccessor." + ACCESSOR_GUESSES[a], as);
		}
	}
	kv("probe.selectorHits", String(hits));
	if (instCount > 0 && hits === 0) {
		kv(
			"probe.note",
			"方法表有 " +
				instCount +
				" 条但候选 selector 零命中——把 PR #480 的确切方法名带入 CANDIDATE/SETTER 列表下一轮",
		);
	}
	kv("probe.verdict", "done");
}
function SETTER_GETTER_GUESSES_SAFE(g) {
	return SETTER_GETTER_PAIRS[g][1];
}

// ── 实例获取 + setter 调用（set/restore 共用）───────────────────────
function bridgeName(sel) {
	// setMCLLimit:error: → setMCLLimitError（JXA 桥驼峰去冒号形态）
	return sel.replace(/:$/, "").replace(/:(.)/g, function (m, c) {
		return c.toUpperCase();
	});
}
function acquireInstance() {
	for (var i = 0; i < CANDIDATE_FRAMEWORKS.length; i++) {
		if (
			frameworkExists(CANDIDATE_FRAMEWORKS[i]) &&
			!SKIP[CANDIDATE_FRAMEWORKS[i]]
		) {
			try {
				ObjC.import(CANDIDATE_FRAMEWORKS[i]);
			} catch (e) {
				/* ObjC.import 常失效——NSBundle 兜底 */
			}
			loadFrameworkBundle(CANDIDATE_FRAMEWORKS[i]);
		}
	}
	var found = findClass();
	if (!found) {
		throw new Error("class-not-resolved（先跑 probe 完成 E0 发现）");
	}
	for (var a = 0; a < ACCESSOR_GUESSES.length; a++) {
		var acc = ACCESSOR_GUESSES[a];
		try {
			if (found.cls && found.cls.respondsToSelector(acc)) {
				kv("set.accessor", acc + " (类方法)");
				return { inst: found.cls[acc](), clsName: found.name };
			}
		} catch (e) {
			/* 探测失败继续 */
		}
	}
	// 2026-09-29 实测定版：PowerUISmartChargeClient 无 shared 单例——唯一实例化路径 = initWithClientName:
	//（方法表枚举：+remoteInterface 非实例 accessor；init 裸不在实例方法表中，走它会失去与 PowerUIAgent 的连接）
	try {
		var named = found.cls.alloc().initWithClientName("Cellar");
		if (named && !named.isNil()) {
			kv("set.accessor", 'alloc/initWithClientName:"Cellar"');
			return { inst: named, clsName: found.name };
		}
	} catch (e2) {
		kv("set.init", "initWithClientName failed: " + e2.message);
	}
	kv(
		"set.accessor",
		"initWithClientName 不可用 → alloc/init 兜底（连接可能缺席，setter 结果如实记录）",
	);
	return { inst: found.cls.alloc().init(), clsName: found.name };
}

function callSetter(n) {
	var ctx = acquireInstance();
	var inst = ctx.inst;
	var tried = [];
	for (var i = 0; i < SETTER_GUESSES.length; i++) {
		var sel = SETTER_GUESSES[i];
		var jsName = bridgeName(sel);
		var responds = null;
		try {
			responds = inst.respondsToSelector(sel);
		} catch (e) {
			responds = null;
		}
		if (responds === false) {
			continue;
		} // respondsToSelector=false → 不试
		tried.push(sel);
		try {
			kv("set.try", sel + "(" + n + ")");
			var r;
			if (/:error:$/.test(sel)) {
				r = inst[jsName](n, Ref()); // NSError** 出参走 Ref()（桥约定）
			} else if (/:withHandler:$/.test(sel)) {
				r = inst[jsName](n, function () {}); // 回调块不需要结果——空函数
			} else {
				r = inst[jsName](n);
			}
			kv("set.called", sel);
			kv(
				"set.return",
				typeof r !== "undefined" &&
					r !== null &&
					typeof r.isNil === "function" &&
					!r.isNil()
					? String(r.description)
					: safeStr(r),
			);
			// 写后回读（判据④素材）：getMCLLimitWithError 返回 unsigned char 上限
			try {
				var rb = inst.getMCLLimitWithError(Ref());
				kv("set.readback.mclLimit", safeStr(rb));
			} catch (e2) {
				kv("set.readback", "failed: " + e2.message);
			}
			kv(
				"set.verdict",
				"called(观察面：battlimit/充电行为——判读臂与 S2 同款，包装器负责采样)",
			);
			return;
		} catch (e) {
			kv("set.error", sel + ": " + e.message);
		}
	}
	throw new Error(
		"no-callable-setter (tried: " +
			tried.join(", ") +
			")——把 probe 探针结果反馈下一轮",
	);
}

// ── 主入口（osascript 把脚本后的参数传给 run(argv)）─────────────────
function run(argv) {
	var cmd = argv.length > 0 ? argv[0] : "probe";
	if (argv.indexOf("--skip") !== -1) {
		var idx = argv.indexOf("--skip");
		var names = String(argv[idx + 1] || "").split(",");
		for (var s = 0; s < names.length; s++) {
			if (names[s]) {
				SKIP[names[s]] = true;
			}
		}
		kv("probe.skip", names.join(","));
	}
	if (cmd === "probe") {
		probe();
		return OUT.join("\n");
	}
	if (cmd === "set") {
		var n = parseInt(argv[1], 10);
		if (isNaN(n) || n < 0 || n > 100) {
			throw new Error("set 需要合法整数 0–100，收到: " + argv[1]);
		}
		if (n < 80) {
			kv(
				"set.warn",
				"n<80——PR #480 预期 segfault/错误域；形态由 .sh 包装在独立子进程捕获",
			);
		}
		callSetter(n);
		return OUT.join("\n");
	}
	if (cmd === "restore") {
		var target = argv.length > 1 ? parseInt(argv[1], 10) : 100;
		try {
			callSetter(target);
			kv("restore.verdict", "set-to-" + target);
		} catch (e) {
			kv("restore.verdict", "interface-failed: " + e.message);
			kv(
				"restore.fallback",
				"系统设置 → 电池 → 充电上限 UI 操作（PowerUIAgent 正门，R7 万能兜底）",
			);
		}
		return OUT.join("\n");
	}
	throw new Error(
		"未知子命令: " + cmd + "（可用：probe | set <n> | restore [n]）",
	);
}
