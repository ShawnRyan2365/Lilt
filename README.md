<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/lilt-logo-light.svg">
    <img src="assets/brand/lilt-logo.svg" alt="Lilt" width="280">
  </picture>
</p>

# Lilt

**一台 Mac 上管理多个 Claude Pro / Max 账号：看额度、一键换号，额度用完自动接力。**

macOS 菜单栏小工具。你照常在终端里用官方 `claude`，Lilt 负责告诉你每个账号还剩多少额度，并在需要时把 Claude Code 的登录换成下一个账号。

<p align="center">
  <img src="assets/relay.gif" alt="当前账号额度到阈值后，Lilt 自动接力到下一个账号" width="860">
</p>

<p align="center"><sub>演示模式：账号和额度都是虚构的。“日常创作”的额度到了阈值，Lilt 自动换到“深度工作”。</sub></p>

## 它能做什么

- **一眼看额度**：每个账号的 5 小时和 7 天额度各剩多少、什么时候重置，蓝色是 5 小时，绿色是 7 天。
- **一键换号**：点一下账号，终端里的 `claude` 就用上它，不需要重新登录，也不需要特别的启动命令。
- **自动接力**：打开后，当前账号任一额度剩余 ≤1% 时，Lilt 按顺序找下一个还有额度的账号换上。都不够时停下来，并逐个说明原因。
- **自动排序**（默认关）：按 7 天额度排接力顺序，先重置的在前，同一天重置的剩余多的在前，快过期的周额度先用掉，晚重置的账号留作后备。换号时优先换到 5 小时额度还没动过的账号，并一直用到阈值再换。
- **常驻菜单栏**：按 ⌘⌥L 随时打开面板（设置里可改为 ⌘⌥J / ⌘⌥K）。

<p align="center">
  <img src="assets/panel.png" alt="菜单栏面板" width="300">
  <img src="assets/accounts.png" alt="账号列表：额度、接力顺序和切换" width="540">
</p>

<p align="center">
  <img src="assets/dark.png" alt="深色模式下的概览页" width="760">
</p>

<p align="center"><sub>菜单栏面板、账号列表和深色模式。</sub></p>

## Lilt 不是反代

**Lilt 和反代、网关、模型中转没有任何关系。**

- **不经手模型请求。** 你在终端里用的仍是官方 `claude`，对话由它直接发给 Anthropic。Lilt 不在中间，不转发、不改写，也不记录任何对话内容。
- **只发三种请求，全部发往官方域名，并拒绝重定向：** 读额度（`api.anthropic.com/api/oauth/usage`）、核对账号身份（`api.anthropic.com/api/oauth/profile`）、给不在用的登录续期（`platform.claude.com/v1/oauth/token`）。没有第三方服务器，也没有统计上报。
- **登录走官方流程。** 添加账号时运行官方的 `claude auth login --claudeai`，在浏览器里登录 Claude 官网，Lilt 碰不到你的密码。
- **凭据只留在本机。** 存在只有当前用户能读的文件里，不上传到任何地方。
- **切换账号相当于替你在 Claude Code 里重新登录一次：** 把选中账号的登录写到 Claude Code 读取登录的位置。
- **代码全部公开**，可以自己核对、自己构建。

### 封号风险

Lilt 没有得到 Anthropic 的认可，作者也无法保证不会封号：账号会不会被处理，只有 Anthropic 能决定。使用前请自己读一下相关条款：

- [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)：账号不能分享给别人，违反条款的账号可能被停用。
- [Claude Code 法律与合规](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)：Pro / Max 的额度按“普通的个人使用”来定。自动接力（一个账号额度用完就换下一个）算不算普通的个人使用，条款没有明说。

只用 Lilt 管理你自己的账号，不要把账号或登录交给别人用。

## 下载安装

在 [Releases](https://github.com/ShawnRyan2365/Lilt/releases) 下载 `Lilt-<版本>.dmg`，打开后把 Lilt 拖进“应用程序”。需要 macOS 26+，Apple 芯片和 Intel 都能用。

安装包没有 Apple 开发者签名，也没有经过公证，所以第一次打开会被系统拦下：

1. 双击 Lilt，系统提示“无法验证”，点“完成”。
2. 打开“系统设置 → 隐私与安全性”，在“安全性”一栏找到 Lilt，点“仍要打开”，输入开机密码确认。之后正常打开，不会再问。

如果提示“已损坏，无法打开”，在终端运行下面这行，再打开一次：

```sh
xattr -dr com.apple.quarantine /Applications/Lilt.app
```

不想信任别人编好的程序，可以[自己从源码构建](#从源码构建)；自己构建的应用不会被拦。

## 上手

第一次打开时，概览页一次只给你一步：

1. **接管 Claude Code 默认登录。** 之后在任何终端直接运行 `claude`，用的都是 Lilt 里选中的账号。你现在登录着的账号会加入 Lilt，不会被退出。
2. **添加账号。** 推荐用浏览器登录（完整登录，能看额度、能参与自动接力）。也可以粘贴 `claude setup-token` 生成的长效 Token，但官方额度接口不接受它，这类账号看不到额度、不参与自动接力，只能手动切换。
3. **选一个账号用。** 想让它自动换号，就在概览页打开“自动接力”。

只想先看看效果，点“先看看演示”：三个虚构账号，不碰任何真实凭据。打开演示里的自动接力，再点“模拟到阈值”，就能看到上面动图里的接力。

## 现在的状态

0.1 研究预览版，能用，但还有没在真实账号上验证过的部分：

- **切换后，已经在运行的 `claude` 会不会立刻用上新账号，还没有实测。** 切换后请在 CLI 里用 `/status` 核对；不放心就重开一次会话。
- 真实账号下的自动接力还没有完整跑过。
- 如果 ORCA 等工具也在切换 Claude 账号，两边会互相覆盖。Lilt 发现登录被别人改过会停下来，让你选择采纳还是改回，不会硬覆盖。请只保留一个管理方。

## 数据放在哪里

- 账号列表和偏好：`~/Library/Application Support/Lilt/accounts.json`，不含凭据。
- 每个账号的登录凭据：`~/Library/Application Support/Lilt/secrets/`，权限 0600，只有当前用户能读。
- 接管后，Lilt 写入 Claude Code 自己读取登录的位置：钥匙串条目 `Claude Code-credentials`（通过系统的 `security` 工具读写）、已存在时的 `~/.claude/.credentials.json`、`~/.claude.json` 里的 `oauthAccount`。
- 实时额度（默认开，可在“接入”页关闭）：在 `~/.claude/settings.json` 的状态栏命令前加一个小脚本，只取 Claude Code 交给状态栏的额度数据，终端里显示的内容不变。第一次改动前会把原文件备份为 `claude-settings-before-lilt.json`，关闭时放回原来的状态栏。
- 额度查询有节制：自动接力开着时当前账号每 5 分钟查一次（剩余 ≤10% 时每 2 分钟），其他账号只在需要接力或手动刷新时才查。遇到限流时全部暂停，等官方允许再查。
- 不修改 shell 配置、网络或代理设置。

## 从源码构建

需要 macOS 26+ 与 Swift 6.2+，没有第三方依赖。Command Line Tools 就够；装有 Xcode 时会顺带编译强调色资源。

```sh
swift run LiltChecks          # 规则检查
./scripts/build-app.sh        # 生成 build/Lilt.app（本机架构）
open build/Lilt.app
```

`./scripts/package.sh` 生成 Apple 芯片与 Intel 通用版本，并打成 `build/Lilt-<版本>.dmg`，需要装有 Xcode。

Logo、透明 PNG、SVG 和 App Icon 预览在 [`assets/brand`](assets/brand)。设计与重新生成方法见[品牌资产说明](assets/brand/README.md)。

## 许可

[MIT](LICENSE)。Lilt 是个人项目，不是 Anthropic 官方产品，与 Anthropic 没有关联。
