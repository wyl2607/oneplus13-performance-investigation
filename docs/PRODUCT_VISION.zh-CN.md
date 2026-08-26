# 产品定位：Adaptive Performance Controller for OPlus / SM8750

> 状态：产品方向文档，不是实测事实记录  
> 当前首要设备：OnePlus 13 / SM8750  
> 当前实现基础：`mitigation/op13perf/` + 真机实验体系

---

# 1. 我们接下来的目标

这个项目下一阶段不再只把自己定义成“调查 OnePlus 13 为什么跑不满”或“做一个性能模式脚本”。

新的长期定位是：

> **Adaptive Performance Controller for OPlus / SM8750**  
> 自动识别 OEM 性能限制、工作负载和热状态，在不关闭最终硬件/内核安全保护的前提下，把 CPU/GPU 的有限功耗预算分配给边际 perf/W 更高的部分，并且所有策略都可验证、可回滚、可按设备适配。

核心不是“频率数字更高”，而是：

```text
同样的温度 / 功耗预算
        ↓
更合理的调度、频率和任务放置
        ↓
更高真实吞吐 / 更低延迟 / 更稳定帧时间
```

换句话说，我们要做的是**手机上的 PBO / Curve Optimizer 思路**，而不是“一键拉满”。

---

# 2. 产品原则

## 2.1 成功标准

以下任意一种都可以算成功：

- 同等温度下性能更高；
- 同等性能下温度更低；
- 同等性能下功耗更低；
- 短时交互延迟更低，但不增加长期热负担；
- sustained workload 更稳定，不再“前两分钟爆冲、后面掉悬崖”；
- OEM 的错误限制被解除，但正常安全保护仍保留。

以下不算成功：

- 只看到 `scaling_cur_freq` 更高；
- 只看到一次跑分峰值；
- 通过关闭温控换成绩；
- 通过过压换性能；
- 极限模式更快，但 daily driver 明显更热、更耗电或更不稳定。

## 2.2 安全优先级高于跑分

默认产品策略必须满足：

1. 不关闭 SoC / kernel 最终 thermal emergency；
2. 不默认 overvolt；
3. 不默认启用未验证 OC；
4. 任意策略都有一键恢复 stock；
5. App 崩溃不应导致性能杠杆失控；
6. daemon / watchdog 可以在 UI 不存在时独立回退；
7. 开机连续异常时默认回 stock；
8. 设备或内核版本不匹配时默认禁用写入，只允许诊断。

---

# 3. 产品分层

成熟形态应拆成四层，而不是把所有逻辑塞进一个 App。

```text
┌──────────────────────────────┐
│ Android App                  │
│ UI / diagnostics / charts    │
│ profile selection / reports  │
└──────────────┬───────────────┘
               │ IPC
┌──────────────▼───────────────┐
│ Root daemon                  │
│ workload classifier          │
│ CPU/GPU policy               │
│ thermal controller           │
│ watchdog / rollback          │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ Device capability/profile    │
│ device / SoC / ROM / kernel  │
│ nodes / OPP / limiter map    │
│ known-good / known-bad       │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ Kernel / vendor interfaces   │
│ URCC / uclamp / CFB / cpuset │
│ GPU devfreq / thermal / SCX  │
└──────────────────────────────┘
```

UI 不是安全边界。真正的安全边界应该在 root daemon 和 profile validator。

---

# 4. 第一版 App 应该做什么

第一版不要追求“支持所有骁龙手机”。

更合理的产品是：

> **OnePlus 13 Performance Lab / Adaptive Controller Beta**  
> 只支持我们已经充分研究的 OnePlus 13 版本，做深、做稳、做透明。

## 4.1 首页

展示：

```text
当前模式：Adaptive
设备：OnePlus 13 CPH2653
SoC：SM8750
Kernel：6.6.x

CPU junction：xx °C
Thermal state：NORMAL / HOT1 / HOT2
P6 policy：xxxx MHz cap
P0 policy：xxxx MHz cap
CFB：stock / managed
uclamp recovery：active / inactive
held verification：yes / no
```

## 4.2 用户模式

Stable 用户只需要：

```text
Stock
Adaptive
Performance burst
Cooled extreme
```

不要把几十个 sysfs 参数直接扔给普通用户。

## 4.3 一键恢复

必须始终有：

```text
恢复原厂 / Emergency restore
```

并明确显示：

- 当前有哪些节点由我们控制；
- 恢复后读回是否成功；
- 是否需要重启才能完全恢复 vendor 状态。

---

# 5. Stable Mode 与 Lab Mode

## Stable Mode

给朋友和普通 Root 用户使用。

只允许：

- 已验证设备；
- 已验证内核 / ROM 范围；
- 已通过 A/B 与稳定性测试的 profile；
- 无 overvolt；
- 无未经验证 OC；
- 强制 watchdog；
- 强制 read-back；
- 强制自动回退。

## Lab Mode

给开发和高级用户。

可以开放：

- P6 / P0 OPP sweep；
- thermal state 参数；
- uclamp / affinity 实验；
- GPU UV；
- custom kernel / HMBIRD / SCX A/B；
- OC 实验；
- benchmark harness；
- 原始日志导出。

Lab Mode 必须有醒目的风险边界，而且不能成为默认开机状态。

---

# 6. 自动诊断：安装后先读，不先写

成熟 App 安装后第一步应该是只读诊断：

```text
Device: OnePlus 13 CPH2653
SoC: SM8750
Kernel: 6.6.118
ROM build: CPH2653_xxx

policy0: CPUs 0-5
policy6: CPUs 6-7

URCC node: found
cpufreq_bouncing: found
oplus_bsp_task_overload: found
thermal sensor: found
GPU table access: unknown / supported / blocked
HMBIRD/SCX: unavailable / available
```

然后生成 feature matrix：

```text
✅ CPU adaptive budget
✅ uclamp recovery
✅ thermal PBO
⚠ GPU Curve Optimizer: experimental
❌ custom kernel profile: unsupported on this build
```

若 fingerprint / kernel /节点布局不匹配，默认进入：

```text
DIAGNOSTIC-ONLY
```

而不是“猜着写”。

---

# 7. 设备 Profile 不是一张静态频率表

以后 `devices/` 中每个 profile 至少应包含：

```text
device_key
model / region
soc
android_version
rom_build_range
kernel_release_range
kernel_fingerprint

cpu_policies
available_opps
rated_max
vendor_limiters
required_nodes
optional_nodes
thermal_sensors

safe_default_policy
known_good_profiles
known_bad_features
recovery_actions
```

并区分：

```text
supported
experimental
unsupported
```

同为 SM8750 不代表策略可以直接复用。

---

# 8. 自动标定：长期最重要的差异化功能

成熟版本不应该永远依赖作者手工找参数。

我们最终希望实现一个低风险 calibration flow：

```text
1. 读 OPP / limiter / thermal capability
2. 测 stock baseline
3. 扫描安全范围内的候选
4. 交替 A/B
5. 记录 performance + thermal burden
6. 找 Pareto frontier
7. 给出推荐 profile
8. 保存本机 calibration report
```

例如：

```text
Calibration result

Stock:          861 work
Candidate A:   1008 work / +thermal
Candidate B:   1050 work / same thermal

Recommended P6/P0:
2438400 / 2400000
Confidence: high
Runs: 8
```

自动标定的目标不是“自动超频”，而是：

> **自动寻找这台具体设备在安全边界内的 perf/W sweet spot。**

---

# 9. 控制器最终形态

长期目标应该有两个不同时间尺度的控制环。

## Fast loop：交互 / frame / launch

时间尺度：约几十毫秒到数百毫秒。

输入：

- touch / swipe；
- app launch；
- window switch；
- RenderThread / frame critical；
- short heavy-load hint。

输出：

- bounded uclamp.min；
- affinity/cpuset；
- short burst ceiling；
- 提前结束 boost。

## Slow loop：持续功耗 / thermal PBO

时间尺度：约数百毫秒到数秒。

输入：

- sustained load；
- P6/P0 aggregate demand；
- junction temperature；
- thermal area；
- GPU load；
- 是否有主动散热。

输出：

- P6/P0 budget allocation；
- NORMAL / HOT1 / HOT2；
- GPU cap/UV policy；
- emergency release。

不要把 Fast 与 Slow loop 混成一个“温度高就降频”的状态机。

---

# 10. 给朋友使用前必须满足的发布门槛

任何 Stable Beta 至少满足：

- 设备识别严格；
- stock restore 实机验证；
- daemon 崩溃测试；
- App 强杀测试；
- 屏幕关闭 / 唤醒测试；
- 开机恢复测试；
- thermal gate 真实触发测试；
- 30–60 分钟 sustained workload；
- 游戏 / UI / app launch / CPU / GPU 多类 workload；
- OTA 后 profile 自动失效或重新验证；
- 无已知 bootloop / watchdog / GPU reset；
- 日志能解释“当前是谁在控制哪个节点”。

---

# 11. 多设备扩展策略

扩展顺序：

```text
OnePlus 13
↓
同 SoC、相近 OPlus 内核家族
↓
OnePlus 13T / Realme GT7 Pro 等
↓
更多 OPlus SM8750
↓
再考虑其他 Snapdragon 平台
```

先做“少设备、深适配”，不要做“200 台手机一份通用参数”。

外部贡献流程应要求：

- `diagnose.sh` 输出；
- ROM/kernel fingerprint；
- OPP 表；
- limiter presence；
- baseline；
- A/B 数据；
- thermal metrics；
- recovery verification。

---

# 12. 项目对外表述

推荐描述：

> **Adaptive Performance Controller for OPlus / SM8750**  
> A measurement-driven performance controller that detects vendor limits and dynamically allocates CPU/GPU thermal and power budget for better real-world performance without disabling final hardware safety protections.

中文：

> **面向 OPlus / SM8750 的自适应性能控制器。**  
> 基于真机测量识别厂商性能限制，并按负载与热状态动态分配 CPU/GPU 功耗预算；目标是在不关闭最终硬件安全保护的前提下，获得更好的真实性能、能效和持续稳定性。

不要使用：

```text
unlock all performance
thermal killer
max FPS booster
one-click OC
```

这种无法被数据和安全模型支撑的定位。

---

# 13. 下一步

产品化不能打断当前最重要的研究链。当前顺序仍然是：

```text
1. 完成 CPU P6 sweet-spot A/B
2. 重做多级 thermal PBO
3. workload-aware uclamp / affinity
4. 外部 scheduler / SM8750 kernel 研究
5. GPU UV / Curve Optimizer
6. custom kernel A/B
7. App + daemon Beta
8. 多设备 profile
9. 自动标定成熟化
10. 最后才研究真正 OC
```

`docs/PERFORMANCE_OPTIMIZATION_PLAN.zh-CN.md` 负责研究顺序；本文件负责回答我们最终要做成什么。