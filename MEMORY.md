# 披露式记忆

## 2026-09-02：Windows 实机 ADB 兼容性排查

### Bug 1：ADB shell 脚本参数被 Windows 拆分

- 现象：原版 smoke test 在真实设备上执行 `adb shell sh -c ...` 时失败，设备报 `/system/bin/sh: syntax error: unexpected 'then'`。
- 根因：`sh`、`-c` 和脚本被作为多个 ADB 参数传递；Windows 版 ADB 没有保留脚本边界。
- 影响：只读节点读取中断，smoke test 错误地把 ADB/root/preflight 标为失败。
- 修复：在 `tools/adb-integration-smoke.py` 和 `tools/upstream-backends.py` 中，将 `sh -c '<script>'` / `su -c '<script>'` 作为单个 ADB 参数传递。
- 回归验证：新增 `tests/test_adb_integration_smoke.py`，参数边界测试已通过；修复后的实机 smoke 已通过该阶段。
- 状态：已修复；全量测试、编译检查和实机 smoke 均已通过，已提交并推送至 PR #29。

### Bug 2：Windows 控制台 Unicode 解码/输出失败

- 现象：设备状态中的 `left=常开` 被 Python 读成 `left=å¸¸å¼€`；固定子进程 UTF-8 解码后，Python 3.14 在 cp1252 标准输出上打印 JSON 又触发 `UnicodeEncodeError`，导致新快照未写回。
- 根因：ADB 输出是 UTF-8，但 Windows Python 默认使用本地编码处理子进程文本和标准输出。
- 影响：快照字段损坏；一次 smoke 重跑在打印阶段退出，未能完成新快照写入。
- 当前修复：ADB 子进程显式使用 UTF-8；CLI 输出尝试在打印前将标准输出重配置为 UTF-8。
- 验证结果：子进程 UTF-8 回归测试已通过；标准输出修复后的实机 smoke 返回 0，JSON 成功写回，`left=常开` 保持正确中文。
- 状态：已修复；全量测试、编译检查和实机 smoke 均已通过，已提交并推送至 PR #29。

### 操作失误 3：快照文件补丁格式错误

- 现象：首次新增 `data/live/initial-device-state.txt` 的补丁在末尾漏写新增行标记，`apply_patch` 拒绝应用。
- 影响：快照文件当时没有创建；已有文件未被修改。
- 处理：记录后重新读取本文件，再使用校正后的完整补丁重试。
- 验证结果：校正后的补丁已成功创建快照文件，内容包含本次 smoke 的真实设备字段。
- 状态：已处理。

### 安全阻断 4：真实设备快照不应随修复 PR 外传

- 现象：推送 commit `ca6b979` 时被安全策略拒绝，因为 commit 包含真实设备序列号、构建指纹、root 状态和进程信息。
- 影响：没有任何内容被推送到 GitHub；远端没有新增数据。
- 处理：保留 `data/live` 快照在本机，但从 PR commit 中移除该目录；PR 只保留代码修复、回归测试和不含设备身份信息的披露式记忆。
- 验证结果：快照已从 Git 索引移除并保留在本机；amend 后的修复 commit 不包含 `data/live`。
- 状态：已处理；修复分支已安全推送并创建 PR #29，`data/live` 仍仅保留在本机。
