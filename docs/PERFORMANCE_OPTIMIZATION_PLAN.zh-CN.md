# OnePlus 13 自适应性能优化 / PBO 研究计划

> 状态：研究路线图（不是实测事实记录）  
> 设备基线：OnePlus 13 / SM8750 / Android 16 / 已 Root  
> 目标：在不关闭最终硬件/内核安全保护、不默认加压的前提下，找到可重复、可回滚、可量化的“近零成本性能”，并逐步把 `op13perf` 从固定档位升级成 workload-aware 的自适应性能控制器。

---

## 0. 文档边界

本文件只回答：**接下来研究什么、按什么顺序、如何判断值得合入。**

- `docs/DATA.md`：只记录已经在真机上得到的数据与被验证/被推翻的事实。
- `docs/METHODOLOGY.md`：记录实验方法、控制变量和测量口径。
- `mitigation/op13perf/`：只放已经达到可用标准的缓解/性能控制实现。
- 本文件：允许写假设、候选方案、外部项目调研、实验排期和淘汰条件。

任何外部仓库里的参数、频率、电压、调度配置，**在本机复测前都只能算线索，不能算答案。**

---

# 1. 最终目标：做“手机上的 PBO”，不是做固定高频 OC

本项目不把“最高频率数字更大”定义为成功。

最终目标是一个反馈控制器：

```text
workload / frame / touch / top-app
                │
                ▼
        workload classifier
          │      │      │
       burst    CPU     GPU
          │      │      │
          └── power-budget policy ──┐
                                    ▼
                          CPU P6 / P0 allocation
                          uclamp / affinity
                          GPU DVFS / optional UV
                                    │
                                    ▼
                         thermal / stability feedback
                                    │
                           raise / hold / retreat
```

核心原则：

1. **优先消除错误的软件限制，而不是突破额定硬件极限。**
2. **优先优化 marginal perf/W（每增加一点热/功耗得到多少性能）。**
3. **优先 undervolt / budget reallocation，再考虑 overclock。**
4. **任何性能结论都必须来自 A/B 复测，而不是来自 `scaling_cur_freq` 或配置值。**
5. **任何性能模式都必须有立即回滚到 stock 的路径。**

---

# 2. 已知基线：后续研究不能推翻这些边界

当前仓库已经确认 OnePlus 13 上至少存在三类互相独立的 CPU 限制/控制：

- URCC / `msm_performance` 维护的 `cpu_max_freq` 请求；
- `oplus_bsp_task_overload` 对繁忙前台线程的 `uclamp.max` 钳制与迁核影响；
- `cpufreq_bouncing` 通过 `freq_qos` 在持续负载后施加额外上限。

当前重要结构：

```text
policy0: CPU0-5，6 个核，额定 3532800
policy6: CPU6-7，2 个 prime，额定 4320000
```

因此所有“全核性能”实验必须显式覆盖 P0 的六核贡献。只跑两条 prime-pinned worker 的实验不能外推到八核持续负载。

最近全核实验给出的工作假设：

- 八核持续负载下，简单抬 P6/P0 ceiling 并没有得到可区分的持续吞吐收益；
- P6 与 P0 存在明显共享功耗/热预算竞争；
- 限制 P6 可能把预算释放给 6 个 P0，从而在相近温度下得到更高 aggregate work；
- 当前 thermal retreat 同时砍 P0 的方向可能不是最优，甚至可能把预算错误地推给低 perf/W 的高频 prime。

这些目前仍需要交替 A/B 复测才能成为正式配置。

---

# 3. 安全红线（所有阶段通用）

## 3.1 永远不做

- 不关闭 SoC / 内核最终 thermal emergency / hardware trip；
- 不把“屏蔽温控”当成性能优化；
- 不默认 overvolt CPU/GPU；
- 不直接照抄别人设备的 GPU 电压表；
- 不在 daily profile 中写不存在的 OPP；
- 不同时引入多个新控制器后再测性能（无法归因）；
- 不让两个 daemon 同时写同一组 CPU/GPU sysfs 节点；
- 不把一次跑分、一次峰值频率或一次最佳结果当成结论。

## 3.2 研究阶段的硬退场条件

实验 harness 应拥有独立于被测策略的 hard abort：

- junction 瞬时达到 100 °C：立即终止实验并回 stock；
- EMA / 平滑结温长期进入 ≥95 °C 区间：终止该裸机候选；
- 出现 kernel panic、GPU reset、WDT、黑屏、图形 artifact、数据损坏迹象：候选立即淘汰；
- 任何候选无法通过“关闭模块 / 重启恢复 stock”：禁止进入下一阶段。

上述数值是**实验安全门，不是 OEM 硬件额定值声明**；后续可根据 `THERMALS.md` 的真实传感器证据调整，但只能更严格地修改默认策略。

---

# 4. 统一测量框架：先把实验仪器升级，再继续调参

## 4.1 所有性能实验至少记录

```text
total_work
mid_work
prime_work
run_duration
start_junction_temp
mean_junction_temp
p95_junction_temp
peak_junction_temp
time_over_85C
time_over_88C
thermal_area_80
stepped_down_ratio
battery_soc_start/end
crash/reset count
```

`thermal_area_80`：

```text
sum(max(T - 80C, 0) * dt)
```

用来区分“短暂尖峰”与“长期贴高温运行”。

## 4.2 频率测量

`scaling_cur_freq` 的 1 Hz 瞬时抽样不作为机制归因的主证据。

优先尝试：

```text
/sys/devices/system/cpu/cpufreq/policy*/stats/time_in_state
```

如果 stock kernel 不暴露，则接受“拿不到 residency”，不要为了一个低价值指标引入额外侵入性改动。最终性能仍以 work / latency / frame time 为准。

## 4.3 A/B 规则

候选必须交替运行，例如：

```text
A B A B A B
```

或：

```text
A B B A B A A B
```

禁止先跑完 AAAA 再跑 BBBB。

开始条件至少控制：

- 起始 junction 温度尽量 ±1 °C；
- 起始 SOC 在同一窄区间；
- 同一屏幕状态、亮度、充电状态、散热器状态；
- 无并发 harness；
- harness 带单实例锁；
- TERM/INT 必须真实 exit，并等待 worker 全部消失后才允许下一轮。

## 4.4 合入阈值

默认采用保守门槛：

- 性能提升必须跨多次复测仍保持同方向；
- 如果预期收益 ≤5%，必须增加重复次数；
- 若吞吐只提升但 thermal burden 明显恶化，不算“免费性能”；
- 优先选择 Pareto 改进：性能更高且温度/能耗不差，或性能相同但更冷/更省电。

---

# 5. Phase A — CPU PBO：先找 P6 sweet spot

**优先级：最高。保持 stock kernel。**

## 假设

P6 两个 prime 在高频段的 marginal perf/W 低于 P0 六核。限制 P6 可能释放共享预算，让 P0 做更多 aggregate work。

## 实验

固定：

```text
P0 = 2400000
CFB = 与当前有效实验策略一致
uclamp = 与当前有效实验策略一致
thermal gate = 固定
```

只扫描 P6 的真实 OPP，候选至少覆盖：

```text
2246400
2438400
2649600
2841600
```

必要时围绕最优点增加一档上下邻点。

## 输出

绘制/记录：

```text
P6 cap -> total work
P6 cap -> mid work
P6 cap -> prime work
P6 cap -> thermal_area_80
P6 cap -> p95 temp
```

## Gate A

只有在交替 A/B 中确认一个 P6 sweet spot 后，才允许修改 `DAILY_P6`。

当前重点候选：`2438400 / 2400000`，但在复测完成前禁止标为“最佳”。

---

# 6. Phase B — 重写 thermal retreat：从单一 COOL 变成多级 PBO

**前提：Gate A 通过。**

当前 `NORMAL -> COOL` 的二态控制器要升级成多级状态机，并且任何 thermal cap 必须满足：

```text
thermal_cap <= profile_cap
```

禁止出现“正常档 P6 已经降到 2438400，但过热后 COOL_P6 反而写 2649600”的反向升频。

候选结构：

```text
NORMAL
  P6 = sweet spot
  P0 = daily baseline

HOT-1
  先降 P6 一个 OPP
  P0 保持

HOT-2
  P6 再降或保持
  P0 小降一个 OPP

EMERGENCY
  立即 release / stock-safe path
```

研究目标：验证“先削 prime、后削 P0”是否比当前两簇同时降更优。

Gate B：

- 同等或更低 thermal burden；
- aggregate throughput 不低于旧 COOL；
- 无 gate 抖动；
- 无永久卡在 retreat 的不可恢复状态；
- profile 与 thermal 状态转换全部有日志与 read-back verification。

---

# 7. Phase C — workload-aware uclamp / affinity

**前提：CPU ceiling 与 thermal controller 已稳定。**

现在 top-app 的 `uclamp.max=1024` 主要作用是解除 OPLUS 的错误钳制。下一步不应简单变成“所有 top-app 全程 boost”，而是研究任务类型。

候选 workload：

```text
interactive/UI burst
RenderThread / frame-critical
wake/sleep-heavy worker
continuous compute
background
screen-off
```

研究问题：

1. 哪些线程必须解除 `uclamp.max` 才能避免被迁出 prime？
2. 是否能只对 frame-critical / wake-heavy 线程解除，而减少整个 top-app 的无差别干预？
3. `uclamp.min` 的短时 boost 能否改善 frame / launch latency 而不提高持续温度？
4. affinity/cpuset 是否比提高 ceiling 更有效？
5. 游戏是否走独立 `game_opt` 路径，导致普通 top-app 策略失效？

Gate C：真实场景至少覆盖 app launch、连续滑动/动画、持续 CPU、游戏/逐帧 workload；不能只靠 Geekbench。

---

# 8. 外部仓库逐个研究计划

以下按**研究顺序**排列。原则是先学思想/提取差异，再决定是否移植；不会直接把第三方模块和 `op13perf` 同时启用。

---

## R1. `yc9559/uperf`

仓库：<https://github.com/yc9559/uperf>

### 为什么研究

它是成熟的 Android 用户态性能控制器，包含：触摸识别、前台 app 切换、负载采样、UI 线程亲和性、SurfaceFlinger 场景、待机场景、多性能模式等。

### 要研究什么

- 触摸 / swipe / heavy-load 状态机如何实现；
- 如何识别 top app 切换而不过度依赖 Android Framework；
- UI 线程 affinity 的发现与生命周期管理；
- heavy-load 进入/退出的防抖逻辑；
- 它如何避免 boost 长时间滞留；
- 配置层如何把“事件”映射到 sysfs 操作。

### 我们要借的东西

**借 workload detection 架构，不借旧 SoC 参数。**

### 明确不做

第一阶段不把 Uperf daemon 与 `op13perf` 并行运行，因为两者可能同时写 CPU 参数，造成 controller fight。

### 产出

`research/uperf-notes.md`：事件源、状态机、可复用机制、与 Android 16 / SM8750 不兼容点。

---

## R2. `helloklf/scheduler`（Scene 调度配置）

仓库：<https://github.com/helloklf/scheduler>

### 为什么研究

Scene 的配置抽象覆盖 CPU/GPU 频率、cpuset、affinity、`uclamp.min`、优先级、多模式和游戏/线程特化，适合借鉴“控制器接口”设计。

### 要研究什么

- `@set_priority` 对 top-app/foreground/background 的抽象；
- cpuset 与 affinity 协同；
- heavy thread / UnityMain 线程识别；
- CPU/GPU frequency helper 如何对不存在 OPP 做吸附；
- profile/preset/import 结构，能否用于重构 `op13perf` 配置；
- `turbo`/强行大核策略为什么可能在大型游戏中反而压垮大核。

### 我们要借的东西

配置模型、线程分组思想、helper 的 read/validate/round-to-real-OPP 设计。

### 明确不做

不直接复制 Scene 的“高/最大/turbo”参数到 SM8750；我们的 URCC/CFB/task_overload 路径不同。

### 产出

`research/scene-scheduler-notes.md`：抽象层设计草案 + 可映射到 `op13perf` 的接口。

---

## R3. `cctv18/oppo_oplus_realme_sm8750`

仓库：<https://github.com/cctv18/oppo_oplus_realme_sm8750>

### 为什么研究

这是直接面向 OPLUS / OnePlus / Realme SM8750 的 6.6 内核构建项目，包含 OKI/GKI 构建路线、官方驱动/调度保留思路、风驰 SCX/HMBIRD 移植和 OnePlus 13 源码适配。

### 要研究什么

- OnePlus 13 对应源码 branch/tag 与当前手机内核版本的匹配方式；
- OKI 与 GKI 对 vendor scheduler / f2fs / modules ABI 的差异；
- 风驰/HMBIRD/SCX 实际修改了哪些 scheduler hooks；
- 它的 `SCHED_PATCH` / patch application 顺序；
- 编译时 O2、LTO、I/O patch 等“性能优化”哪些有可独立验证价值；
- 哪些改动只是 root/SUSFS/网络功能，与性能无关，应从性能实验里剥离。

### 第一阶段只做

源码/patch diff 审计，不刷机。

### Gate

只有能构建出与 stock 接近、且明确知道新增 patch 集合的 kernel，才进入刷机 A/B。

### 产出

`research/cctv18-sm8750-notes.md` + patch inventory。

---

## R4. `qdykernel/Build_Oneplus_Realme_Action`

仓库：<https://github.com/qdykernel/Build_Oneplus_Realme_Action>

### 为什么研究

提供 OnePlus 13 / SM8750 的 OKI 自动构建，并明确集成风驰调度补丁；是 cctv18 路线的独立对照。

### 要研究什么

- OnePlus 13 workflow 的 source ref / config / patch 顺序；
- 与 cctv18 的共同补丁和差异补丁；
- `Numbersf/SCHED_PATCH` 集成方式；
- AnyKernel3 打包与回滚流程；
- “性能优化”中哪些是 scheduler 变化，哪些只是编译器/通用 patch。

### 目的

不是找“谁跑分更高”，而是找两个项目**共同选择的 scheduler 变化**以及其中真正可单变量 A/B 的部分。

### 产出

`research/qdy-sm8750-notes.md` + 与 cctv18 的 diff matrix。

---

## R5. `WildKernels/OnePlus_KernelSU_SUSFS`

仓库：<https://github.com/WildKernels/OnePlus_KernelSU_SUSFS>

### 为什么研究

这个项目同时维护 OnePlus/Oppo/Realme kernel 构建，并列出 HMBIRD SCX、memory/I/O/CPU scheduler 等优化，还维护 OnePlusOSS 变更跟踪。

### 要研究什么

- HMBIRD SCX 的启用条件与补丁来源；
- `kernel_patches` 中真正影响 CPU scheduler / cpufreq / memory latency 的 patch；
- OnePlusOSS tracking 如何发现上游源码变化；
- 把 root/SUSFS/baseband/network 功能从性能 patch 中剥离；
- 哪些 patch 在 SM8750 上有真实 benchmark/latency 证据，哪些只是 generic tuning。

### 产出

`research/wildkernels-notes.md` + scheduler/perf-only patch shortlist。

---

## R6. `ox1d3x3/Op13_Susfs_kernel`

仓库：<https://github.com/ox1d3x3/Op13_Susfs_kernel>

### 为什么研究

这是明确以 OnePlus 13 daily-driver 稳定性为目标的 GKI 2.0 构建。其当前 release/default 思路中 **FengChi/HMBIRD 默认关闭以优先稳定性**，非常适合作为“不要因为有 patch 就默认打开”的反向对照。

### 要研究什么

- `stock_daily` / `stock_plus` / `minimal_safe` profile 的实际差异；
- 为什么 FengChi/HMBIRD 默认 off；
- `_ox_debug/config-scan.txt` 与 optional-patches audit 的验证机制；
- O2 vs O3 的策略与风险；
- stable baseline 怎样逐个重新引入 ADIOS / scheduler / memory patch。

### 用途

如果以后进入 custom-kernel 阶段，先建立“stock-like custom kernel”控制组，再测试 HMBIRD，而不是直接刷 full-feature build。

### 产出

`research/ox1d3x3-op13-notes.md` + custom-kernel baseline checklist。

---

## R7. `KonaBess-Next/KonaBess-Next`

仓库：<https://github.com/KonaBess-Next/KonaBess-Next>

### 为什么研究

它面向现代 Snapdragon，支持编辑 GPU frequency / voltage table，并明确覆盖 Snapdragon 8 Elite。它是最接近桌面 Curve Optimizer 的路线。

### 研究顺序

**只从 stock-frequency undervolt 开始，不从 OC 开始。**

1. 备份当前 boot/vendor_boot/dtb 相关镜像；
2. 只读导出当前 Adreno DVFS / voltage table；
3. 确认 OnePlus 13 对应 DTB 节点与 KonaBess Next parser 是否正确；
4. 每次只改一个电压区间/一个小步；
5. 保持 stock GPU frequency ceiling；
6. 做 GPU stability suite；
7. 只有稳定 UV 已确认后，才评估是否存在 thermal headroom 可转化为更高持续 GPU/CPU 性能。

### GPU stability suite

至少覆盖：

- 3D 图形循环；
- Vulkan workload；
- OpenCL/compute；
- 长时间游戏；
- 熄屏/亮屏；
- app 切换；
- 视频播放/编解码；
- 冷启动与热机状态。

观察：GPU reset、driver timeout、artifact、黑屏、随机 app crash，而不只是 benchmark 是否跑完。

### 明确禁止

- 不照抄他人电压值；
- 不在建立稳定 UV 曲线之前 overvolt；
- 不把一次 3DMark 通过当稳定。

### 产出

`research/konabess-next-op13-notes.md` + stock GPU table snapshot + UV validation matrix。

---

## R8. `OnePlusOSS` 官方 SM8750 源码 / manifest

入口：<https://github.com/OnePlusOSS>

### 为什么研究

第三方 patch 必须有 source-of-truth 对照。官方源码虽然可能不完整，但它仍然是判断 vendor scheduler、module ABI、cpufreq、thermal、HMBIRD 接口变化的基线。

### 要研究什么

- 与本机 `uname -r` / build fingerprint 对应的公开 branch；
- `oplus_bsp_task_overload`、`cpufreq_bouncing`、URCC/msm_performance 相关源码是否可见；
- sched_ext / HMBIRD / WALT 接口版本；
- thermal zone / cooling device / freq_qos 的 vendor hook；
- OTA 后源码变化是否会让现有 `op13perf` 假设失效。

### 产出

`research/oneplusoss-sm8750-notes.md` + “stock source ↔ device behavior” 对照表。

---

## R9. `Numbersf/SCHED_PATCH` / 风驰调度补丁来源

入口：由 qdy/cctv18 依赖链确认具体 ref 后锁定。

### 为什么研究

不能把“HMBIRD/风驰”当成一个黑盒 feature flag。需要知道它到底修改哪些 scheduler hook、调度 class、任务 placement、uclamp/boost 语义，以及与 OPLUS 自有模块怎样交互。

### 要研究什么

- patch 文件列表和依赖；
- 对 EAS/WALT/sched_ext 的侵入点；
- 与 `oplus_bsp_task_overload` 是否叠加或替代；
- 是否改变 `top-app` / game path；
- 是否改变我们的 current harness 观测含义。

### 产出

`research/fengchi-hmbird-notes.md` + minimum patch set。

---

# 9. Phase D — custom kernel A/B（只有前面都完成才进入）

自定义内核阶段必须拆成控制组：

```text
K0 = stock kernel + current op13perf
K1 = stock-like custom kernel，无 HMBIRD、无额外 performance patch
K2 = K1 + HMBIRD/SCX only
K3 = K2 + 单个候选 scheduler patch
...
```

禁止：

```text
stock -> 一次刷入 HMBIRD + O3 + ADIOS + memory tweaks + network tweaks
```

因为这种对比即使快了也无法知道为什么。

## Custom-kernel Gate

每个 kernel 至少验证：

- 正常启动；
- Wi-Fi / modem / camera / display / fingerprint；
- suspend/resume；
- 充电；
- root；
- thermal sensors；
- cpufreq policies；
- 原有 URCC/CFB/task_overload 行为是否仍存在；
- 30–60 min 稳定性；
- 可恢复 stock boot/init_boot。

通过后才进入性能 A/B。

---

# 10. Phase E — GPU Curve Optimizer

前提：CPU userspace PBO 与 custom-kernel 研究已经有稳定基线，避免 CPU/GPU 同时变化。

优先路线：

```text
stock frequency + mild UV
        ↓
测相同性能下 GPU power / junction / sustained clock
        ↓
如果 thermal headroom 释放
        ↓
观察 CPU 是否得到额外共享预算
        ↓
最后才考虑 optional GPU OC
```

成功定义不是“GPU 频率更高”，而是：

- 同性能更低 thermal burden；或
- 同热预算更高 sustained GPU performance；或
- GPU workload 下 CPU 获得更多共享功耗预算而改善 frame pacing。

---

# 11. Phase F — 真 OC 只作为最后 5% 的实验功能

CPU 真 OC / overvolt 暂不进入主路线。

只有当：

1. 软件限制已解决；
2. CPU P6/P0 budget sweet spot 已确定；
3. thermal controller 已优化；
4. workload-aware 调度已验证；
5. GPU UV 已完成；
6. custom-kernel baseline 稳定；

仍然存在明确单线程/特定 workload 的频率瓶颈，才研究超额 OPP。

默认规则：

- 不默认 overvolt；
- OC profile 不自动开机；
- 必须要求主动散热；
- 必须与同温度/同功耗的 non-OC baseline 比较；
- 如果只提高单核、却降低多核/持续性能，则只保留为 benchmark/short-burst 实验档，不进入 daily。

---

# 12. 真实 workload suite

最终版本不能只优化 benchmark。

至少维护四类测试：

## CPU sustained

- 全核 harness；
- wake/sleep-heavy worker；
- continuous compute worker；
- 编译/压缩类负载。

## Interactive

- app cold/warm launch；
- 连续列表滑动；
- 系统动画；
- frame time / jank；
- app switch。

## Game / frame-driven

- CPU-heavy game scene；
- GPU-heavy game scene；
- 30/60/120 FPS 不同目标；
- 至少 15–30 min sustained。

## GPU compute / graphics

- Vulkan；
- OpenCL；
- 3D loop；
- mixed CPU+GPU workload。

每个阶段都要回答：**提升是 benchmark-only，还是现实 workload 也存在？**

---

# 13. 研究执行顺序 / 当前 backlog

按顺序推进，前一个 Gate 未通过不进入高风险下一层。

- [ ] **A1** 完成当前 `s-deep`，保存第二轮完整数据。
- [ ] **A2** 现状 Daily vs `P6=2438400/P0=2400000` 做交替 A/B 复测。
- [ ] **A3** 固定 P0，扫描 P6 OPP sweet spot。
- [ ] **A4** 将 `thermal_area_80` / p95 / time-over-threshold 加入 harness。
- [ ] **B1** 设计 `NORMAL -> HOT1 -> HOT2 -> EMERGENCY` 状态机。
- [ ] **B2** 验证 thermal cap 永远不高于 profile cap。
- [ ] **B3** 旧 COOL vs prime-first retreat A/B。
- [ ] **R1** 深读 Uperf，提取 workload detection 架构。
- [ ] **R2** 深读 Scene scheduler，提取 uclamp/cpuset/affinity 配置抽象。
- [ ] **C1** 做 workload-aware top-app/uclamp prototype。
- [ ] **C2** 加 interactive / frame-driven workload suite。
- [ ] **R3** 审计 cctv18 SM8750 builder 与 HMBIRD patch 链。
- [ ] **R4** 审计 qdykernel builder，与 cctv18 做 patch diff。
- [ ] **R5** 审计 WildKernels performance-only patch。
- [ ] **R6** 审计 ox1d3x3 stable baseline / HMBIRD-off 决策。
- [ ] **R8** 建 OnePlusOSS source-of-truth 对照。
- [ ] **R9** 单独拆解 FengChi/HMBIRD minimum patch set。
- [ ] **D1** 构建 K1：stock-like custom kernel，无额外 performance patch。
- [ ] **D2** K0 vs K1 稳定性和性能 A/B。
- [ ] **D3** K1 vs K2（只加 HMBIRD/SCX）。
- [ ] **R7** 审计 KonaBess Next 对 OP13 / SM8750 DTB 的适配路径。
- [ ] **E1** 导出并保存 stock GPU DVFS/voltage table。
- [ ] **E2** stock-frequency mild UV 单点测试。
- [ ] **E3** 建立 UV stability matrix。
- [ ] **E4** 验证 UV 是否释放 mixed CPU/GPU thermal budget。
- [ ] **F1** 仅在以上全部完成后评估 GPU OC。
- [ ] **F2** CPU 真 OC / overvolt 默认保持搁置，除非出现明确未解决瓶颈。

---

# 14. 每个外部项目的统一研究模板

以后每研究一个仓库，都按下面结构写 notes，避免变成“看了一圈觉得不错”：

```text
Repo / commit / branch:
Last reviewed:
Device/platform target:

1. 它试图解决什么问题？
2. 它具体写了哪些 kernel/sysfs/DTB/voltage/scheduler 节点？
3. 哪些行为与 stock OnePlus 13 重叠？
4. 哪些行为会和 op13perf 冲突？
5. 能拆成单变量实验的最小改动是什么？
6. 有什么 boot / thermal / stability 风险？
7. 如何完全回滚？
8. 我们的 baseline/harness 能否测出它声称的收益？
9. 结论：ADOPT / TEST / WATCH / REJECT
10. 下一步实验编号：
```

任何 `ADOPT` 都必须有本机 A/B 数据链接回 `DATA.md`。

---

# 15. 目标形态

如果整个计划成功，`op13perf` 最终应从固定档位模块演变为：

```text
OP13 Adaptive Performance Controller

├── limiter discovery
│   ├── URCC
│   ├── task_overload
│   └── cpufreq_bouncing
│
├── workload classifier
│   ├── interactive
│   ├── sustained CPU
│   ├── frame/game
│   └── GPU-heavy
│
├── CPU optimizer
│   ├── P6 marginal perf/W
│   ├── P0 marginal perf/W
│   ├── uclamp
│   └── affinity/cpuset
│
├── GPU optimizer
│   ├── stock DVFS
│   ├── validated UV
│   └── optional OC
│
├── thermal controller
│   ├── NORMAL
│   ├── HOT1
│   ├── HOT2
│   └── EMERGENCY/STOCK
│
└── validation
    ├── throughput
    ├── latency/frame-time
    ├── thermal area
    ├── energy
    └── stability
```

最终成功标准：**比 stock 更快，但不是靠长期更热；比固定暴力性能档更聪明；每一项收益都能指出机制、数据和回滚路径。**
