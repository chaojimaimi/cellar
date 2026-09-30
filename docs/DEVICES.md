# Cellar 设备信息行（`cellar doctor --devices`）

`cellar doctor --devices` 输出**单行**机器可解析的设备信息（`key=value` 空格分隔，
字段序固定），用于机型实测行收录与问题排查。与人类可读的 `cellar doctor` 报告互相
独立：`--devices` 只输出该行，缺值一律 `unknown`。

## 字段表

| 字段                      | 含义           | 值                    | 数据源                            |
| ------------------------- | -------------- | --------------------- | --------------------------------- |
| `device.model`            | 机型标识       | 如 `Mac15,9`          | sysctl `hw.model`                 |
| `device.chip`             | 芯片型号       | 如 `Apple_M4_Pro`     | `machdep.cpu.brand_string`        |
| `device.macos`            | macOS 版本     | 如 `26.6_(26B2064)`   | `sw_vers`                         |
| `device.firmware`         | 固件版本       | 如 `10151.140.19.0.1` | IODeviceTree `rom-version` 固定键 |
| `device.backend`          | 控制后端       | `tahoe` / `legacy`    | 运行时探测                        |
| `device.keys.chte`        | CHTE 键在位    | `yes` / `no`          | SMC 元数据探测                    |
| `device.keys.chie`        | CHIE 键在位    | `yes` / `no`          | SMC 元数据探测                    |
| `device.keys.ch0b`        | CH0B 键在位    | `yes` / `no`          | SMC 元数据探测                    |
| `device.discharge`        | 放电能力       | `yes` / `no`          | supportsDischarge（tahoe ∧ CHIE） |
| `device.limit.verify`     | 限充执法一致性 | `pass` / `unknown`    | daemon 快照 + CHTE 停充回读       |
| `device.discharge.verify` | 放电完成路径   | `pass` / `unknown`    | daemon `lastAction`               |

> 值内空格以 `_` 占位（保持「空格分隔令牌」契约，机器可直接按空格拆分）；
> 字段序固定不增删；布尔值渲染 `yes`/`no`。
>
> `device.limit.verify = pass` 表示瞬时执法一致：限充启用、已外接、电量已达上限
> 且 CHTE 停充回读一致。`device.discharge.verify = pass` 表示最近一次放电已完整
> 走到终点（其余时刻为瞬态 `unknown` 属预期）。

## SMC 控制键世代表（0.20 M1a 实测，随批收录）

按 macOS 代际记录控制键/关键字段的在位与可写性（spike 实测 + 真机巡检；「不可读」=
keyInfo 132 或读失败，「可写」= 同值写探针 0x00→0x00 回读一致——S1 E1 实证幂等安全）：

| macOS 代际 | CHTE | CH0B/CH0C | CHIE | bf 系（bfD0/bfE0/bfF0） | Clamshell（合盖状态） |
| --- | --- | --- | --- | --- | --- |
| 26.x（Tahoe，26.6.2 实测） | ✓ 可读可写（ui32/4B） | ✗ 缺席 | ✓ 可读可写（hex_/1B） | 未测（26 无此需求） | AppleSmartBattery 侧未依赖；合盖闸走 IOPMrootDomain |
| 27 GA（26A428 系，27.0.1 26A434 实测） | **✗ 不可读**（键族被系统删除） | ✗ 缺席 | **✓ 存活可写**（hex_/1B） | **❌ 全部不存在**（keyInfo 132） | **AppleSmartBattery 无 ClamshellState**（全字典 grep 命中 0）；等价字段 = `IOPMrootDomain.AppleClamshellState`（Bool，**非 root 可读**）+ `AppleClamshellCausesSleep`；屏幕唤醒代理 `IOPMUserIsActive` 同服务可读 |

- 27 放电控制面 = CHIE（`RuntimeProbe.dischargeControlPlane` 第三级探测：keyInfo 在位
  + 读成功 + 同值写探针）；充电执法经编排/topoff 通道（topoff 通道 0.20 M1b 落地）。
- **合盖闸作用域（0.20 P1 评审修定）：仅 macOS 27 终态生效**（daemon
  `backendUnavailableTerminal` 同源判别式）——26 及更早 clamshell-mode 手动放电/
  运行续行零变化（闸不介入）。
- **合盖闸局限登记**：强字段（`IOPMrootDomain.AppleClamshellState`）读取失败时降级
  「ext=true ∧ 用户活跃（IOPMUserIsActive）」弱检查——弱检查仅在放电启动路径生效
  （且仅 27）；运行中 30s 粒度中止依赖强字段（不可读时诚实缺席不中止，防误伤开盖
  息屏的合法放电）。代理性质如实标注：`IOPMUserIsActive` 不精确等价显示态。

## 各机型实测行收录表

欢迎在 issue 中附上完整 `cellar doctor --devices` 输出行（并注明机型/芯片/macOS
版本），收录至此表：

| 收录                        | 机型    | 芯片         | macOS  | 实测行                                                                                                                                                                                                                                                            |
| --------------------------- | ------- | ------------ | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ✅ 开发机（端到端验收基线） | Mac14,6 | Apple M2 Max | 26.6.2 | `device.model=Mac14,6 device.chip=Apple_M2_Max device.macos=26.6.2_(25G83) device.firmware=unknown device.backend=tahoe device.keys.chte=yes device.keys.chie=yes device.keys.ch0b=no device.discharge=yes device.limit.verify=pass device.discharge.verify=pass` |
| 待收录                      | —       | —            | —      | —                                                                                                                                                                                                                                                                 |

## 隐私与提交提醒

- `--devices` 输出为固定字段白名单，不包含任何个人标识信息（固件仅取
  `rom-version` 单键，不做整字典输出）。
- **提 issue 时请勿附序列号/UUID** 等设备特有标识；直接贴 `cellar doctor --devices`
  输出行即可——该行已按白名单生成，足够定位机型与固件问题。
