# op13perf 快捷设置磁贴

通知栏下拉面板里一键循环切档，磁贴上能看到当前档名。不必打开 Magisk 点 Action，也不必回桌面弹 Termux 窗口。

切档接口与 Magisk Action / Termux:Widget 相同：`echo <N> > /data/adb/op13perf/state`，N 为 0/1/2/3。守护进程自己轮询该文件，不用重启。循环顺序与 `action.sh` 一致：关 → 日常档 → 高性能档 → 极限档 → 关。

档位名来自模块里的 `desc.sh`（`lvlname`），本目录不另写一份当作真相。Kotlin 里的中文名只在 `su` 读不到 `desc.sh` 时回退。

读/写 `/data/adb/` 都要 root，通过 `su -c` 执行。

## 构建（电脑侧）

本目录**故意不带** Gradle Wrapper 的 jar。需要本机已装：

- JDK 17
- Android SDK（`compileSdk` / `targetSdk` 35）
- Gradle 8.9+（与 AGP 8.7.2 匹配）

`ANDROID_HOME` 或 `local.properties` 里的 `sdk.dir` 指向 SDK。在本目录：

```
gradle assembleDebug
```

APK 在 `app/build/outputs/apk/debug/app-debug.apk`。

没有真机、没有 Android SDK 的环境编不过，这是预期。

## 安装

设备已 root（Magisk），且 `op13perf` 模块已装。

```
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

这个 App **没有桌面图标**。装完不会在启动器里出现，从快捷设置编辑页把它拖进去。

## 添加到快捷设置

1. 从屏幕顶部下拉，打开快捷设置
2. 点编辑（铅笔 / 「编辑」）
3. 在可用磁贴里找到 **op13perf**，拖进面板

首次出现在列表里的时机、ColorOS 是否把无桌面图标的 App 藏起来，都没在真机上看过。

## 第一次点需要 Magisk 授权

磁贴跑在本 App 的 uid 下，读 `state` / `status`、写 `state` 都必须 `su`。第一次执行 Magisk 会弹窗，给 **op13perf** 授权（可勾选记住）。

没授权的话，磁贴 subtitle 会写出原因（「等待 Magisk 授权」/「su 被拒绝」），点磁贴会打开一页说明，而不是只显示「失败」。

**如果之前在弹窗里点过拒绝**：Magisk 会记住，之后不再弹窗。打开 Magisk → 超级用户 → 把本应用改成允许，再回到快捷设置点一次。本项目刚在 Termux 上栽过这件事。

`su` 调用有 12 秒超时。授权窗还开着时磁贴不会一直卡死主线程；超时后 subtitle 会提示在等授权。这时不要急着重开说明页——说明页会盖住 Magisk 弹窗。

## 磁贴显示什么

| 部位 | 内容 |
|---|---|
| label | 当前档名（优先 `desc.sh` 的 `lvlname`） |
| subtitle（API 29+） | 结温或 `held=`；拿不到 root 时改成原因 |
| 激活态 | 0 档 `STATE_INACTIVE`，其余 `STATE_ACTIVE` |

每次下拉（`onStartListening`）都重新读设备上的 `state` / `status`，不拿内存缓存当真相。

点一下 = 循环切到下一档，并在 daemon 没在跑时按 `action.sh` 的方式拉起（看 `/proc/<pid>/cmdline` 是否含 `perfd.sh`）。

磁贴**不会**等 5 秒再报内核 `cpu_max_freq`——那是 Action / widget 的报告节奏。这里只写 `state`，daemon 自己轮询。

## 故障排查

- **快捷设置编辑页没有这个磁贴** = 先确认 APK 已装（设置 → 应用 → op13perf）。ColorOS 对无桌面图标应用的磁贴列表行为未验证。
- **subtitle 写着「等待 Magisk 授权」** = 授权窗可能还在，或超时把还在等的 `su` 杀掉了。先处理 Magisk 弹窗，再下拉一次。
- **subtitle 写着「su 被拒绝」/ 弹出说明页** = Magisk 没给本应用授权，或曾经点过拒绝被记住。打开 Magisk → 超级用户 → 允许本应用。
- **subtitle 写着「找不到 su」** = App 进程里起不来 `su`。真机上 `su` 在 `/product/bin/su`，但 App 的 mount namespace 未必看得到这个路径。
- **subtitle 写着「模块未安装」** = `/data/adb/modules/op13perf` 不在。先在 Magisk 里把模块装上并启用。
- **档名变成硬编码的中文、和 Magisk 列表不一致** = `su` 没 source 到 `desc.sh`，走了回退。先看模块是否还在、`desc.sh` 是否可读。
- **切了但实际频率没变** = 先看 subtitle 的 `held=`，或 `cat /data/adb/op13perf/status`。空载时超大核不会顶到目标值，这是内核自己降频，`action.sh` 里写过。daemon 关闭态每 2 秒才轮询一次。

## 已在真机验证 / 仍未验证

2026-08-20 在 CPH2653（Android 16 / SDK 36，Magisk 30.7）上构建、安装并验证。

**已验证**：

- `gradle assembleDebug` 一次编过 —— AGP 8.7.2 + Kotlin 2.0.21 + **Gradle 9.7.1** + JDK 21 + SDK 35，只有弃用警告。（本来预期这个 Gradle 版本会太新，实测没问题。）
- APK 安装成功（`dev.op13perf.tile`，versionName 1.0，811 KB）
- **App 内嵌的两段 shell 从 Kotlin 里提取出来在设备上实跑**，这是磁贴真正会执行的东西：
  - 读状态 → `level=1 name=日常档 held=yes junc=37C`
  - 循环切档 → `1→2→3→0`，每次档名都取自 `desc.sh`（不是回退的硬编码）
  - 切到 0 档后内核确实释放到额定值 `6,7:4320000 / 0-5:3532800`，`status` 变 `off`
- 切档后 `held=` 取到的是**新档**的值。原实现写完 state 立刻读 status，而 daemon 每约 2 秒才刷新一次，读到的会是上一档——已加 `sleep 2.5`。
- 0 档也能显示结温。原实现从 daemon 的 `status` 取温度，而 0 档的 `status` 只有 `off`；已改成直接读 `cpu-1-1-1` 传感器。

**仍未验证**（都需要人在手机上操作，adb 驱动不了——ColorOS 精简了 `cmd statusbar`，没有 `list-tiles` / `click-tile`）：

- ColorOS 快捷设置编辑页是否列出这个磁贴。**已加 LAUNCHER 入口降低风险**：原本刻意不做桌面图标，但 ColorOS 是否会因此藏掉磁贴没人验证过，留个图标同时也给说明页一个入口。
- **App 拿不到 root —— 这是当前已知的未解 bug。** 见下一节。
- 首次 `su` 时 Magisk 弹窗的行为，以及 12 秒超时会不会在用户点允许之前先把 `su` 杀掉。**这个项目已经在 Termux 上栽过一次**：拒绝一旦被记住，Magisk 不再弹窗，表现为静默失败。真出现这情况就直接改：`magisk --sqlite "update policies set policy=2 where uid=<app uid>"`（policy 2 = 允许，1 = 拒绝）。
- 磁贴 UI 本身：label / subtitle 的显示、0 档灰显其余点亮、`onStartListening` 在从 Magisk Action 或 Termux 切档后是否刷新。
- Android 16 上 `startActivityAndCollapse(PendingIntent)` 能否打开说明页。


## 已知未解问题：App 请求 su 被拒，且 Magisk 没有留下记录

2026-08-20，装机后机主点磁贴报错。诊断到目前为止：

```
app uid                          10066
app 进程里 command -v su         /product/bin/su   （-> ./magisk）
run-as 下 su -c id               Permission denied
magisk --sqlite select * from policies where uid=10066   → 空
```

**推翻了一半的原假设。** 之前列的头号嫌疑是「App 的 mount namespace 里看不见 `su`」——实测**看得见**，路径和 adb 侧一样。所以问题不在找不到 su，在于请求被拒。

**策略表里没有 10066 这一条,是这里最值得注意的地方。** Termux 那次是有 `policy=1` 记录的（用户点了拒绝，Magisk 记住了）。这次连记录都没有，意味着从来没有产生过一个「决定」——弹窗没出现，或者出现了但没被响应，或者请求在到达 Magisk 的授权流程之前就被挡掉了。

**这个测试本身有局限，不要过度解读。** `run-as` 派生自 adb shell，SELinux 上下文是 `u:r:shell:s0` 一脉，未必等同于真实 App 进程的 `u:r:untrusted_app:s0`。所以 `Permission denied` 可能是 `run-as` 环境特有的，也可能就是真实 App 的遭遇——目前**分不出来**，需要在真实点击磁贴之后立刻看 `policies` 表和 logcat 才能判定。

**下一步的判定方法**（尚未执行）：点一次磁贴，然后立刻

```
adb shell su -c 'magisk --sqlite "select * from policies where uid=10066"'
adb logcat -d | grep -iE "magisk|op13perf|su:"
```

- 出现 `policy=1` → 弹窗出现过并被拒（或超时），去 Magisk 超级用户列表手动打开即可。
- 仍然没有记录 → 请求根本没走到授权流程，那才是真问题，与 `run-as` 的结果一致。

**可以直接绕过的办法**（未执行，需要机主同意——这是给一个 App 永久 root）：

```
adb shell su -c 'magisk --sqlite "update policies set policy=2 where uid=10066"'
```

uid 不存在时 `update` 不会插入新行，所以这条只在已经有记录时有效。没有记录的情况下需要 `insert`，或者在 Magisk 的超级用户界面里操作。
