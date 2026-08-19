# op13perf Termux:Widget 桌面快捷方式

点桌面一行就能切档，不必打开 Magisk 循环点 Action。

切档接口与 Magisk Action 相同：`echo <N> > /data/adb/op13perf/state`，N 为 0/1/2/3。守护进程自己轮询该文件，不用重启。

档位名来自模块里的 `desc.sh`（`lvlname`），本目录不另写一份。widget 上「0-原厂」只是文件名，方便排序；报告里 0 档显示的是 desc.sh 的「已关闭」。

## 安装（电脑侧）

设备需已安装 Termux（`com.termux`）和 [Termux:Widget](https://wiki.termux.com/wiki/Termux:Widget)，并已 root（Magisk）。在仓库根目录：

```
adb push mitigation/op13perf/shortcuts /data/local/tmp/op13perf-shortcuts
adb shell su -c 'sh /data/local/tmp/op13perf-shortcuts/install-shortcuts.sh'
```

安装脚本会：

- 创建 `~/.shortcuts/`（五个 widget 入口）和 `~/.op13perf/`（内部库）
- **属主 uid 从 Termux 家目录现读**，不硬编码——Termux 重装或装在第二个 Android 用户下时 uid 会变，而属主错了的表现是 widget 列表空白、任何地方都不报错
- 脚本 `755`，库 `644`，两个目录 `700`

可重复执行，后一次覆盖前一次。

**`_common.sh` 放在 `.shortcuts/` 之外**（`~/.op13perf/`）。Termux:Widget 列的是那个目录里的文件，一个点不动的库摆在列表里只会碍事。

## 添加到桌面

1. 长按桌面空白处，打开「小组件 / Widgets」
2. 找到 **Termux:Widget**，拖一个**列表**小组件到桌面
3. 应看到五行：`0-原厂.sh`、`1-日常档.sh`、`2-高性能档.sh`、`3-极限档.sh`、`状态.sh`

列表为空就看下面的故障排查，不要先怀疑脚本内容。

这些脚本放在 `~/.shortcuts/`，点了会弹出 Termux 窗口，你才看得见输出。`~/.shortcuts/tasks/` 下的脚本不弹窗——**本机实测没装 `termux-toast`**，用 `tasks/` 的话切完档不会有任何反馈，所以这里没用它。

## 第一次点需要 Magisk 授权

快捷方式跑在 Termux 的 uid 下，写 `/data/adb/op13perf/state` 必须 `su`。第一次执行 Magisk 会弹窗，给 **Termux** 授权（可勾选记住）。没授权的话，脚本会提示需要 root，state 不会被改。

## 各脚本做什么

| 文件 | 行为 |
|---|---|
| `0-原厂.sh` … `3-极限档.sh` | 若 daemon 未在跑则按 `action.sh` 的方式拉起（看 `/proc/<pid>/cmdline` 是否含 `perfd.sh`，不用进程名），写入对应 state，等 5 秒，读回内核 `cpu_max_freq` 和结温（`cpu-1-1-1`） |
| `状态.sh` | **不改 state、不拉 daemon**。报告当前档位名、`held=yes/no`、内核实际值、结温、CFB、daemon 是否存活 |

报告优先走 `termux-toast`（若可执行），同时 echo 到终端。**本机实测该文件不存在**（Termux:API 的命令行部分没装），所以目前只有终端输出。装了 `pkg install termux-api` 之后 toast 会自动开始工作，不用改脚本。

等 5 秒是沿用 `action.sh` 的理由：daemon 关闭态每 2 秒才轮询一次，再加一次 status 刷新。没有用 widget 路径重新测过。

## 故障排查

- **widget 空列表** = `.shortcuts` 属主或权限不对（最常见是 root 创建后忘了把属主交还 Termux），或脚本没有可执行位。重新跑安装脚本，它会打印它探测到的 uid。
- **点了没反应 / 提示需要 root** = Termux 没拿到 Magisk 超级用户授权。打开 Magisk → 超级用户 → 允许 Termux。
- **有 toast 没弹出** = 未装 Termux:API（`pkg install termux-api`，并安装配套 App）。终端窗口里的 echo 仍应看得到。
- **切了但 `cpu_max_freq` 仍是旧值** = 先点 `状态.sh` 看 daemon 是否存活、`held=` 和 `/data/adb/op13perf/status`。空载时超大核不会顶到目标值，这是内核自己降频，`action.sh` 里写过。

## 已在真机验证 / 仍未验证

2026-08-20 在 CPH2653 上实测。

**已验证**：安装脚本（uid 探测到 10575，`.shortcuts` 里只有 5 个入口）· `状态.sh` 的完整输出 · 切档到高性能档和日常档，内核 `cpu_max_freq` 读回与目标一致 · `su` 确实在 PATH 里（`/product/bin/su`）· 拿不到 root 时脚本给出明确提示而不是静默失败。

**仍未验证**：桌面 widget 里这五个中文文件名的实际显示 · Termux 首次请求 su 时 Magisk 弹窗的行为——这两项都需要人在手机上操作，adb 看不到。

## 本目录文件

不要改 `perfd.sh` / `action.sh` / `desc.sh`。这里只是桌面入口，档位数字仍以 `/data/adb/op13perf/conf` + `desc.sh` 为准。
