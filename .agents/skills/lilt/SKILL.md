---
name: lilt
description: 开发、测试、安装或运维 Lilt（macOS 菜单栏应用和 Linux 无界面后端）时使用。适用于修改 Lilt 代码、构建静态 Linux 包、通过 SSH 安装 liltd、添加 Claude Pro/Max 账号、查看额度、手动切换、自动接力、排查故障或验证发布；不用于实现模型反代、网关、请求转发或账号池。
---

# Lilt

Lilt 管理本机多个 Claude Pro/Max 账号、5 小时/7 天额度、手动切换和自动接力。官方 Claude Code 始终直接连接 Anthropic；Lilt 只处理登录、凭据、额度和账号选择。

## 先区分任务

- **修改代码**：先读 `docs/PRD.md`、`docs/RESEARCH.md`、`.wolf/STATUS.md` 和 `.wolf/cerebrum.md`。不要自动创建索引。
- **构建或发布**：确认实际版本、目标架构和交付物，不沿用旧包的验证结论。
- **SSH 运维**：先确认服务器、运行 Claude Code 的用户、架构和当前状态。默认只做安装与只读检查；真实切换、模型请求和自动接力需要用户明确授权。

## 不可违反的边界

- 不加入模型反代、网关、模型请求转发或云端账号池。
- 不把重启 Claude Code 当成切换的默认条件；优先验证运行时热切换，重启仅为安全兜底。
- 不读取、输出、提交或保存真实 Token、refresh token、认证码、账号标识、授权链接或凭据内容。测试只用虚构数据。
- 不把凭据写入命令行参数、普通日志、Git 或诊断报告。setup-token 只从 stdin 读取。
- 不擅自切换用户账号、覆盖 ORCA/CC Switch 管理的认证状态、重放可能产生副作用的 CLI 操作或启用 linger。
- 完整 OAuth 和 setup-token 不混称能力相同：setup-token 不能读取订阅额度，只能手动切换，不参与自动接力。
- 缺失或过期额度是未知，不是充足或耗尽。默认阈值为剩余 ≤1%。
- 同一凭据作用域中的多个 CLI 可能一起切换，不承诺进程级独立账号。
- 缓存连续性与会话连续性分别验证；没有真实数据时不声称跨账号缓存共享或节省比例。
- 项目固定账号：每个项目一个独立配置目录，只影响从项目入口（macOS“启动项目”、`lilt run --project`）启动的 CLI；项目账号不参与默认自动接力，到阈值只提示。不改写已运行进程的环境，不强退 Orca/终端，也不声称已迁移。启动失败绝不回退到普通 `claude`。
- 账号迁移只做口令加密的一次性导出/导入：口令只从终端或安全输入框读取；导入只新增、默认停用并关闭自动接力，不写运行时、不覆盖已有账号；输出只有数量。导出文件与口令都能使用账号，不要放进 Git、日志或诊断。

## 代码结构

- `Sources/LiltCore/`：额度、阈值、候选排序、提前量、接力、逐事件 spool、项目绑定规则、导入事务、OAuth 文档与安全文件等纯规则（只依赖 Foundation）。
- `Sources/LiltTransfer/`：口令加密归档（scrypt + AES-GCM），唯一依赖 swift-crypto 的模块。
- `Sources/Lilt/`：macOS SwiftUI、AppModel、macOS 钥匙串/文件 RuntimeScope（默认、旧 dedicated、项目）、项目页、迁移和更新器。SwiftPM 产品名为 `LiltApp`。
- `Sources/LiltBackend/`：XDG 存储、文件 RuntimeScope、Claude 目录锁、OAuth 服务、HeadlessEngine、状态栏、Unix socket 与 systemd。
- `Sources/LiltCLI/`：单个 `lilt` 可执行文件及其 `daemon` 子命令。
- `Tests/LiltCoreTests/`、`Tests/LiltBackendTests/`、`Tests/LiltModelTests/`：虚构数据检查。

macOS 只保留一个最新可启动副本，通常为 `~/Applications/Lilt.app`。不要在项目或 worktree 留下竞争的应用副本，不要替用户点击更新或切换账号。

## 构建与检查

按改动范围运行，不能只验证导入或编译：

```sh
swift run LiltChecks
swift run LiltBackendChecks
bash scripts/check-relay-model.sh
swift build
swift build --product lilt
bash scripts/check-linux-cli.sh
```

macOS 应用包：

```sh
bash scripts/build-app.sh
```

Linux 默认构建不得尝试编译 SwiftUI。Linux CI 使用 `swift:6.2` 容器；静态发布使用 Swift Static Linux SDK：

```sh
./scripts/build-linux.sh
```

静态包应分别验证 ARM64 和 x86-64：stripped、无动态依赖，并在不含 Swift runtime 的对应架构容器中执行 `scripts/check-linux-cli.sh`。`build/linux/SHA256SUMS` 必须对应当次最终包。

## 通过 SSH 安装和运维

所有操作都在运行 Claude Code 的同一个普通用户下完成，不使用 root 或 sudo，不开 TCP/HTTP 端口。

1. 用 `uname -m` 选择 arm64（aarch64）或 x86-64（x86_64）包，对照 `SHA256SUMS` 校验后上传。
2. 解压并安装到 `~/.local/bin/lilt`，确认 `lilt version`。
3. 检查 `claude --version` 和 `systemctl --user`。
4. 执行 `lilt service install`，再用 `systemctl --user status liltd` 和 `lilt status` 验证。
5. 已有 Claude 登录时执行 `lilt takeover`。全新服务器先 `lilt login`，由用户在官方流程中完成授权，再 `lilt takeover`。
6. 添加完整 OAuth 账号：`lilt login --label <备注>`。需要 setup-token 时仅通过 stdin 添加。
7. 只做只读检查时到此为止。真实切换和自动接力必须获得用户明确授权。

常用命令：

```sh
lilt list
lilt status
lilt refresh
lilt switch <序号|备注|UUID>
lilt auto on
lilt auto off
lilt auto once
lilt config set five-hour-threshold <0-20>
lilt config set seven-day-threshold <0-20>
lilt statusline on|off
lilt project bind|rebind <目录> <账号> [--allow-shared]
lilt project list|status [目录]
lilt project unbind <目录>
lilt run --project <目录> [-- <claude 参数>]
lilt export <新文件>
lilt import <归档>
lilt release
lilt service install|uninstall|status
lilt daemon
```

如果 systemd user service 不可用，报告原因，不改用 root service。退出 SSH 后的常驻需要 linger 时，先取得用户同意。更新时替换二进制，执行 `systemctl --user restart liltd`，再检查版本与状态。

## 真实验收与故障处理

容器和虚构数据只能证明规则与端到端调用，不能证明真实热切换。真实验收需要分别确认：

- systemd 安装、重启、崩溃恢复和（用户允许时的）linger。
- 官方 OAuth 登录及 usage/profile/renewal 的真实响应。
- 两个受控账号切换前后 PID、工作目录和会话不变，下一次请求确实使用目标身份。
- setup-token 的能力限制、429、外部凭据修改、多 CLI 和长期自动接力。
- 缓存是否重建以真实计数为准，不从速度或界面推断。

凭据写入成功只能报告为“已应用，等待请求身份验证”。无法确认归属、外部工具同时管理、持续读取失败或额度未知时，不强行覆盖。故障报告只写版本、状态和脱敏原因。

停止管理但保留当前 Claude 登录用 `lilt release`；停止并移除用户服务用 `lilt service uninstall`。删除账号库、凭据或 Claude 配置必须另有明确授权。
