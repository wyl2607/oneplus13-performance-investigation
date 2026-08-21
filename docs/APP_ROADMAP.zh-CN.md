# OnePlus 13 Adaptive Controller — App / 产品化路线图

> 本文件负责回答：从当前 Magisk + shell 研究项目，如何一步步变成可以给其他用户使用的成熟 App。

---

# 1. 产品化阶段

## Stage 0 — Research Prototype（当前）

形态：

```text
GitHub
Magisk module
shell daemon
ADB harness
manual A/B
```

目标：

- 找清 vendor limiter；
- 建立可信实验体系；
- 确定 CPU P6/P0 sweet spot；
- 确定 thermal PBO 状态机；
- 把所有“为什么这么设”变成可复现实验，而不是经验参数。

退出条件：

- Daily / thermal 策略不再有已知逻辑漂移；
- CPU 主线至少有一套重复 A/B 支撑的 stable 候选；
- stock restore 完整验证。

---

## Stage 1 — Controller Core

先把 shell 逻辑整理成稳定接口，再做漂亮 UI。

建议组件：

```text
controller/
  capability_probe
  profile_loader
  cpu_policy
  thermal_policy
  workload_state
  writer
  verifier
  watchdog
  logger
```

必须解决：

- 所有写节点只有一个 owner；
- profile 切换原子化；
- 写后 read-back；
- crash 后恢复；
- boot state 恢复；
- single-instance lock；
- 配置 schema 校验；
- 任何 thermal cap 不得反向高于 profile cap。

这个阶段可以继续用 shell，但要按模块边界重构。

---

## Stage 2 — Read-only Android App

第一版 APK **不写任何性能节点**。

功能：

- 设备信息；
- kernel/ROM fingerprint；
- policy0/policy6 拓扑；
- OPP 表；
- URCC / CFB / task_overload 探测；
- thermal sensor；
- daemon 状态；
- 当前 profile / held 状态；
- 导出诊断报告。

目的：

- 先验证 Android App 与 root backend 的 IPC；
- 先把设备兼容性判断做好；
- App 自己不成为控制器。

推荐 UI：

```text
Overview
Device
CPU
Thermal
Limiters
Compatibility
Logs
```

---

## Stage 3 — OnePlus 13 Stable Beta

这才是第一版真正给朋友用的版本。

### Stable UI 只暴露四个模式

```text
Stock
Adaptive
Performance Burst
Cooled Extreme
```

Advanced / Lab 页面才开放底层参数。

### 必须有的卡片

**Compatibility**

```text
Device supported: YES
ROM build: supported
Kernel: supported
Profile revision: 12
```

**Controller**

```text
Adaptive active
Thermal state: NORMAL
P6 cap: xxxx
P0 cap: xxxx
uclamp recovery: active
CFB managed: yes
```

**Safety**

```text
Watchdog: running
Last restore test: passed
Thermal emergency: untouched
```

**Restore stock**

始终可见。

---

# 2. App / daemon 通信

UI 不能直接到处 `su -c echo ...`。

建议：

```text
Android App
   │
   │ local IPC / command interface
   ▼
root controller daemon
   │
   ├── status snapshot
   ├── set profile
   ├── restore stock
   ├── start calibration
   ├── stop calibration
   └── export report
```

接口应尽量声明式：

```text
set_profile adaptive
```

而不是 UI 发：

```text
echo 2438400 > node1
echo 2400000 > node2
uclampset ...
```

所有安全约束放在 daemon。

---

# 3. 建议状态模型

## 用户 profile

```text
STOCK
ADAPTIVE
PERFORMANCE
COOLED_EXTREME
LAB
```

## 内部 thermal state

```text
NORMAL
HOT1
HOT2
EMERGENCY
```

## workload hint

```text
IDLE
INTERACTION
LAUNCH
FRAME_CRITICAL
SUSTAINED_CPU
GPU_HEAVY
GAME
```

三个维度不要混成一个 enum。

最终策略应类似：

```text
output = policy(profile, thermal_state, workload_hint, device_capability)
```

---

# 4. Device Profile Schema

建议未来增加：

```text
devices/
  oneplus13-cph2653/
    profile.yaml
    opps.json
    safety.yaml
    known-builds.json
    notes.md
```

`profile.yaml` 示例概念：

```yaml
device_key: oneplus13-cph2653
soc: sm8750

match:
  models:
    - CPH2653
  kernel_regex: '^6\.6\.'

cpu:
  policies:
    p0:
      cpus: [0,1,2,3,4,5]
    p6:
      cpus: [6,7]

limiters:
  urcc:
    required: true
  cpufreq_bouncing:
    required: true
  task_overload:
    required: true

features:
  adaptive_cpu: stable
  gpu_uv: experimental
  hmbird: experimental
```

真实 schema 后续再设计，关键原则是**先匹配能力，再加载参数**。

---

# 5. Version / OTA 策略

系统 OTA 是成熟 App 必须正面解决的问题。

每次启动检查：

```text
model
build fingerprint
kernel release
关键 module / node presence
OPP hash
```

若发生未知变化：

```text
KNOWN GOOD
   ↓ OTA
UNKNOWN BUILD
   ↓
禁止自动启用写入 profile
   ↓
Diagnostic-only
```

用户可以手动进入 Lab，但 Stable 不应该猜。

以后可以维护：

```text
known-builds.json
```

记录：

```text
build
kernel
status
validated_profile_revision
known_issues
```

---

# 6. 自动标定模块

## Calibration Level 1 — CPU Safe Sweep

只用额定 OPP 范围，不 OC，不改电压。

流程：

```text
preflight
↓
stock baseline
↓
P6 candidates
↓
A/B alternating runs
↓
thermal metrics
↓
Pareto selection
↓
recommendation
```

任何点触发 hard-abort 立即回 stock。

## Calibration Level 2 — Thermal Policy

比较：

```text
old COOL
prime-first HOT1
prime-first HOT2
```

目标不是让温度永远不升，而是在 thermal budget 内损失最少的真实工作量。

## Calibration Level 3 — Interaction

测：

- app launch；
- scrolling；
- frame time；
- bounded uclamp hint。

## Calibration Level 4 — GPU UV

仅 Lab / Advanced。

必须：

- 备份 boot/vendor_boot；
- 单步降低；
- 多 workload 稳定测试；
- GPU reset 检测；
- 恢复路径。

---

# 7. 结果与可信度

App 不应该只显示“优化成功”。

建议输出：

```text
Recommended profile: Adaptive-v3

CPU sustained:
+4.8% median work

Thermal:
p95 -1.2 C
thermal_area_80 -8%

Runs:
A = 4
B = 4

Confidence:
Medium / High
```

并允许用户查看原始 run。

如果结果在噪声内：

```text
No measurable improvement
```

也应该是合法结果。

---

# 8. Telemetry / Privacy

第一版默认不需要任何云端遥测。

推荐：

```text
local logs only
manual export
manual GitHub issue attachment
```

如果未来要做匿名兼容性数据库，必须 opt-in，并明确只上传：

- 设备型号；
- build/kernel；
- limiter capability；
- benchmark summary；
- crash signature。

不要上传包名、个人文件、账户信息等无关数据。

---

# 9. 发布通道

建议：

```text
Research
  ↓
Nightly/Lab
  ↓
Beta
  ↓
Stable
```

## Research

开发者自己使用。

## Nightly/Lab

高级用户，自行接受实验风险。

## Beta

只支持明确列出的 OnePlus 13 build。

## Stable

必须通过完整 regression matrix。

---

# 10. Regression Matrix

每次 Stable profile 或 daemon 大改，至少检查：

| 类别 | 测试 |
|---|---|
| Boot | 冷启动、重启、开机 profile |
| Screen | 熄屏、亮屏、AOD/解锁 |
| App | 强杀 UI App、daemon restart |
| CPU | single、full-core、wake-heavy |
| UI | launch、scroll、animation |
| GPU | 3D workload、video、idle |
| Thermal | gate、HOT1、HOT2、恢复 |
| Recovery | restore stock、reboot stock |
| Stability | 30–60min sustained |
| OTA | unknown-build fail-safe |

---

# 11. 代码仓库未来建议结构

不要求现在马上移动文件，等 Controller Core 稳定后再迁移：

```text
app/
  android/

daemon/
  controller/
  watchdog/
  probe/

devices/
  oneplus13/

calibration/
  cpu/
  thermal/
  gpu/

profiles/
  stable/
  experimental/

research/
  uperf-notes.md
  scheduler-notes.md
  sm8750-kernel-notes.md

experiments/

docs/
```

现有 `mitigation/op13perf/` 在早期仍然是生产实现，不必为了目录漂亮提前重写。

---

# 12. 第一个可发布 Beta 的 Definition of Done

OnePlus 13 Beta 只有同时满足以下条件才发布：

- [ ] 支持型号/构建严格匹配；
- [ ] 未知构建默认 diagnostic-only；
- [ ] Stock / Adaptive 可切换；
- [ ] 一键 restore stock；
- [ ] watchdog 独立运行；
- [ ] daemon crash 后 fail-safe；
- [ ] UI App 被强杀不影响 safety；
- [ ] P6/P0 stable profile 有重复 A/B 数据；
- [ ] thermal state machine 真机触发验证；
- [ ] screen off/on 无漂移；
- [ ] 30–60 分钟 sustained 稳定；
- [ ] 至少一个真实游戏 workload；
- [ ] 至少一个 UI/frame workload；
- [ ] 所有实际写入都有 read-back；
- [ ] 日志可以解释最终 effective state；
- [ ] README 中没有把 experimental 功能写成 stable。

---

# 13. 当前开发顺序

产品化路线必须服从研究证据：

```text
NOW
│
├─ CPU P6 sweet spot
├─ thermal HOT1/HOT2
├─ workload-aware uclamp
├─ R2/R3/... 外部仓库研究
│
▼
Controller Core
│
▼
Read-only App
│
▼
OnePlus 13 Stable Beta
│
├─ optional GPU UV
├─ optional custom kernel/SCX
│
▼
Auto Calibration
│
▼
More OPlus SM8750 devices
```

真正 OC 保持在独立 Lab lane，除非未来数据证明它在日常热预算下存在明确 Pareto 收益。