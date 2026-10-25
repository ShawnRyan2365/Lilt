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
- **自动接力**：打开后，当前账号的 5 小时或 7 天额度剩余到了各自的阈值（默认都是 1%，在设置里分别调）时，Lilt 换到 5 小时额度剩得最多的账号（相差 10 个百分点以内的按接力顺序），换之前先实时查一遍它的额度，不会换到比当前账号剩得还少的账号。同时开着好几个项目、消耗很快时，会按实际消耗速度和上次接力实际花的时间提前换，不再固定最多提前 10 个百分点；几个会话同时上报的额度一条都不丢，取用得最多的那个数。要换上的账号除了高于阈值，还要留够这段时间预计的消耗（至少 2 个百分点），不会换到刚好高于 1% 的账号。快到阈值时按预计到达的时间提前查好首选和一个备选账号。都不够时停下来说明原因，在最早可能有账号可用的时刻（额度重置、退避结束或冷却结束）重新确认。
- **项目固定账号**：给一个项目目录固定一个账号。项目有自己独立的 Claude 配置，只有从 Lilt 项目入口启动的 `claude` 用它；项目账号不参与默认登录的自动接力，到阈值只提示，不自动换号。不同项目互不影响，同一项目里的多个 `claude` 一起换绑。
- **账号迁移**：用口令把账号库加密导出成一个文件，在另一台 Mac 或 Linux 服务器上导入。一次性迁移，不是云同步；导入只新增账号，默认停用，不动那台机器正在用的登录。
- **自动排序**（默认关）：按 7 天额度排接力顺序，先重置的在前，同一天重置的剩余多的在前，快过期的周额度先用掉，晚重置的账号留作后备。换号时仍然先挑 5 小时额度最空的，一样空的再按这个顺序，换上后一直用到阈值再换。
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
- **和账号有关的请求只有三种，全部发往官方域名，并拒绝重定向：** 读额度（`api.anthropic.com/api/oauth/usage`）、核对账号身份（`api.anthropic.com/api/oauth/profile`）、给不在用的登录续期（`platform.claude.com/v1/oauth/token`）。
- **另外只有检查更新会联网：** 每 6 小时向 GitHub 查一次有没有新版本（`api.github.com`，可在设置里关闭），更新时从 GitHub Releases 下载安装包。这两个请求只带 Lilt 的版本号，不含任何账号信息。没有其他第三方服务器，也没有统计上报。
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

### 更新

Lilt 会自己检查新版本。有新版本时，菜单栏面板和管理窗口的工具栏会出现“更新”按钮，点一下就在 App 里下载、校验并替换现在的 Lilt，然后自动重新打开，账号和设置都保留。设置里可以关掉自动检查，也可以从菜单“检查更新…”手动查。0.1.2 及更早的版本还没有这个功能，需要按上面的方法手动装一次新版本。

- 安装包就是 Releases 页面上那个 `Lilt-<版本>.dmg`，同样没有 Apple 开发者签名。Lilt 会核对 GitHub 记录的 SHA-256 和文件大小，确认包里的应用是 Lilt 本身、版本号对得上、签名完整，任何一项不符就放弃，原来的版本不动。
- 正在切换账号、续期或读取额度时，会等它做完再替换，最多等半分钟。
- Lilt 放在没有写权限的位置（比如别的用户装的）时无法自动替换，请到发布页手动下载。

## 上手

第一次打开时，概览页一次只给你一步：

1. **接管 Claude Code 默认登录。** 之后在任何终端直接运行 `claude`，用的都是 Lilt 里选中的账号。你现在登录着的账号会加入 Lilt，不会被退出。
2. **添加账号。** 推荐用浏览器登录（完整登录，能看额度、能参与自动接力）。也可以粘贴 `claude setup-token` 生成的长效 Token，但官方额度接口不接受它，这类账号看不到额度、不参与自动接力，只能手动切换。
3. **选一个账号用。** 想让它自动换号，就在概览页打开“自动接力”。

只想先看看效果，点“先看看演示”：三个虚构账号，不碰任何真实凭据。打开演示里的自动接力，再点“模拟到阈值”，就能看到上面动图里的接力。

## 项目固定账号

在管理窗口的“项目”页点“绑定项目”，选一个项目目录和一个账号。之后点“启动项目”（在“终端”里打开），或者“复制启动命令”贴到自己的终端或编辑器里，启动的就是官方 `claude`：工作目录是项目目录，登录是这个项目的账号。命令只做三件事：进入项目目录，清掉会覆盖登录的环境变量（如 `ANTHROPIC_API_KEY`、`CLAUDE_CODE_OAUTH_TOKEN`），设置项目的 `CLAUDE_CONFIG_DIR`。然后直接运行官方 `claude`，不经过 Lilt。

- **为什么能隔离**：每个项目一个独立的 Claude 配置目录（`~/Library/Application Support/Lilt/projects/<项目 ID>/claude`）和对应的官方钥匙串条目，默认登录和别的项目都不受影响。同一个项目里开几个 `claude`，它们共用这个项目的配置，换绑时一起换。
- **项目账号不会被别处用掉**：绑定后，这个账号不再参与默认登录的自动接力，也不能被手动切进默认登录；删除前要先解绑。同一个账号要给多个项目（或同时给默认登录）用，必须明确确认：额度仍是同一份，而且几处会各自续期同一个登录，服务端若轮换刷新令牌，其中一处可能需要重新登录。
- **固定，不轮换**：项目账号到阈值只提示，不会自动换成别的账号，需要时自己“更换绑定”。换绑写入项目配置后，这个项目里正在运行的 `claude` 会像默认登录一样尝试热切换，不需要重启（真实热切换尚未实测，见下）。
- **已经在运行的终端或 Orca 不会被接管**：它们启动时已经带着自己的环境，Lilt 改不了，也不会强行退出或假装已经迁移。需要的话，安全退出一次，再从项目入口启动；之后同一项目内换绑仍优先热切换。
- **项目用的是全新的 Claude 配置**：用户级 `~/.claude` 里的设置、MCP、记忆和插件不会自动带进项目；项目仓库里的 `.claude/` 配置照常生效。仓库配置里如果写了 API Key、其他服务地址或强制登录方式，Lilt 拒绝接入，不会去改你的仓库文件。
- **会被拒绝的情况**：项目配置里出现 Lilt 认不出的登录（别的工具或别的账号）、上次写入没有完成、钥匙串和文件里各有一份不同的登录、API 覆盖。这些情况下 Lilt 什么都不写，在项目上标出原因，也绝不改用默认登录启动。
- 解绑只停止管理：项目配置、登录和会话历史留着，再绑定同一个目录会找回它们。目录移动后算新项目，需要在新位置重新绑定。

## 账号迁移

设置里的“加密导出账号库…”把全部账号的登录和身份记录用口令加密成一个 `.lilt-credential-export` 文件（scrypt + AES-256-GCM，权限 0600，不会覆盖已有文件）。在另一台机器上用“导入账号库…”或 Linux 的 `lilt import` 导入。

- **文件和口令合在一起就能登录这些账号**，请像对待密码一样保管，用完删除。它和“导出诊断”完全不同。
- **一次性迁移，不是同步**：之后两边各自变化，不会互相更新。两台机器同时用同一个账号时会各自续期同一个登录，先续期的一方可能让另一方的副本失效；迁移后建议在原机器删除或重新授权该账号。
- **导入只新增**：本地已有的账号（同一个 Lilt 账号 ID，或同一个 Claude 账号）跳过；ID 相同但登录不同的算冲突，原来的不动，不会用旧文件覆盖新的登录。新账号默认停用、额度和能力重新验证，并关闭自动接力，确认后再自己打开。导入不碰那台机器正在用的 Claude 登录和正在运行的会话，结果只显示新增、跳过、冲突的数量。

## 现在的状态

0.3 研究预览版，能用，但还有没在真实账号上验证过的部分：

- **切换后，已经在运行的 `claude` 会不会立刻用上新账号，还没有实测。** 按 Claude Code 2.1.308 的代码，正在运行的会话看到 `~/.claude/.credentials.json` 的修改时间变了，会在下一次请求前重新读登录；没有这个文件时，它会把钥匙串里读到的登录最多沿用 30 秒。所以 Lilt 每次切换都会更新这个文件（见下面“数据放在哪里”）。这是读代码得出的，还没有在真实会话里量过。切换后请在 CLI 里用 `/status` 核对；不放心就重开一次会话。
- 真实账号下的自动接力还没有完整跑过。
- 如果 ORCA 等工具也在切换 Claude 账号，两边会互相覆盖。Lilt 发现登录被别人改过会停下来，让你选择采纳还是改回，不会硬覆盖。请只保留一个管理方。
- 切换途中钥匙串一时没有响应（会话很多时偶尔出现），自动接力不会关掉：Lilt 等十几秒再换，切到一半的那次会在钥匙串恢复后自动补完或撤回。只有登录确实被别人换掉、Lilt 认不出来时，才会停下来问你。
- 项目固定账号和账号迁移只用虚构账号、隔离目录和假 `claude` 检查过。项目独立钥匙串条目在真实 `claude` 的下一次请求里是否用上项目账号、项目内换绑的热切换、多个 CLI 和子代理、旧会话迁移、真实缓存计数，都还没有实测。一个会话上报了新账号的额度，只说明至少那一个会话已经接上，不代表同时运行的所有会话都已接上。
- 不承诺跨账号共享缓存、固定的节省比例，也不承诺一定不撞额度墙：官方数据有延迟，一次请求也可能用掉不止 1%。

## Linux 服务器版

Linux 版是独立的 `lilt` 命令行与同用户 `liltd` 后台服务，不需要图形界面，不开 HTTP 端口，也不转发模型请求。CLI 与后台服务只通过当前用户可访问的 Unix socket 通信。账号库、凭据和状态默认分别放在 `~/.local/share/lilt/`、`~/.local/state/lilt/`，遵循对应的 `XDG_*_HOME` 设置；Claude 登录写入 `${CLAUDE_CONFIG_DIR:-~/.claude}/.credentials.json`。

安装静态二进制后，先安装用户服务，再接管或添加账号：

```sh
lilt service install          # 安装并启动 systemd 用户服务
lilt takeover                 # 接管当前 Claude 默认登录
lilt login --label 工作       # 通过官方 CLI 添加完整 OAuth 登录
lilt list
lilt switch 2
lilt auto on
lilt status
```

如果服务器还没有登录过，先运行 `lilt login`，再运行 `lilt takeover`；默认登录为空时会把第一个受管账号应用进去。远程服务器没有本地浏览器时，`lilt login` 仍由官方 CLI 在当前 SSH 终端给出授权流程；按终端提示在浏览器完成即可。也可以添加 `claude setup-token` 的长效 Token，但它读不到订阅额度，只能手动切换，不能参与自动接力。Token 只从标准输入读取：

```sh
read -rsp 'Token: ' TOKEN; echo
printf '%s\n' "$TOKEN" | lilt add-token --label 备用
unset TOKEN
```

项目固定账号（每个项目独立的 `CLAUDE_CONFIG_DIR`，账号不参与默认自动接力）：

```sh
lilt project bind ~/code/app 工作            # 给项目固定账号；同一账号给多处用需加 --allow-shared
lilt project list
lilt project status ~/code/app
lilt run --project ~/code/app -- --continue  # 直接变成官方 claude：同一进程、终端、信号和退出码
lilt project rebind ~/code/app 备用
lilt project unbind ~/code/app               # 只停止管理，保留项目配置和登录
```

`lilt run` 只设置项目的 `CLAUDE_CONFIG_DIR`、清掉会覆盖登录的环境变量，`--` 之后的参数原样交给官方 `claude`，不经过 shell；在项目子目录里运行时保持当前目录。daemon 不可用、项目没有绑定或登录归属不明时直接报错，绝不改用普通 `claude`。`--resume` / `--continue` 只原样传递：项目配置目录里没有默认登录下的旧会话记录。

账号迁移（口令只从当前终端无回显读取，不接受参数或环境变量，归档也不会写到标准输出）：

```sh
lilt export ~/lilt-accounts.lilt-credential-export
lilt import ~/lilt-accounts.lilt-credential-export
```

常用操作：

```sh
lilt refresh                  # 刷新全部账号额度
lilt auto once                # 在 cron/systemd timer 中做一次检查
lilt config set five-hour-threshold 5
lilt config set seven-day-threshold 1
lilt config set auto-sort on
lilt statusline off           # 关闭实时额度并还原原状态栏
lilt release                  # 停止接管，不退出当前 Claude 登录
lilt service uninstall        # 停止并移除用户服务，保留账号库
lilt status --json            # 脚本使用的机器可读输出
lilt daemon                   # 不用 systemd 时前台运行
```

如果希望退出所有 SSH 会话后服务仍运行，系统还需允许该用户 linger；是否启用由服务器管理员决定。多个终端共用同一个凭据作用域时会一起切换，不是每个进程独立绑定账号。

Linux 后端已有隔离 HOME 的规则、文件事务、状态栏、自动接力及 CLI/socket 端到端检查。**真实服务器上的 systemd 生命周期、官方 OAuth 登录、两个真实账号的原会话热切换和长期自动接力仍需受控验收。** 不要把编译和虚构数据检查当作这些真实能力的验收结果。

从源码检查与构建：

```sh
swift run LiltChecks
swift run LiltBackendChecks
swift build --product lilt
bash scripts/check-linux-cli.sh
# 安装 Swift Static Linux SDK 后，构建 ARM64 与 x86-64 静态包：
./scripts/build-linux.sh
```

## 数据放在哪里

- 账号列表和偏好：`~/Library/Application Support/Lilt/accounts.json`，不含凭据。项目绑定在同目录的 `projects.json`，只有目录和 Lilt 自己的账号 ID。
- 项目配置：`~/Library/Application Support/Lilt/projects/<项目 ID>/claude` 是官方 CLI 的配置目录，登录在它对应的官方钥匙串条目里，`.credentials.json` 只写 `{}` 信号；事务记录、锁和状态栏文件在同级的 `state/`。
- 每个账号的登录凭据：`~/Library/Application Support/Lilt/secrets/`，权限 0600，只有当前用户能读。
- macOS 运行时登录只以 Claude Code 官方的钥匙串条目 `Claude Code-credentials` 为准，并同步 `~/.claude.json` 里的 `oauthAccount`。不再提供文件运行时或双向存储设置。`~/.claude/.credentials.json` 只写空的 `{}` 变更信号，提醒运行中的 `claude` 重读钥匙串；停止接管时删除这个信号文件。
- 如果本地文件中也出现有效登录且与钥匙串不一致，Lilt 会停止接力、隐藏当前账号归属并暂停切换，防止两边各走一个账号。用户可明确选择保留钥匙串当前登录，或把文件账号切换到钥匙串；处理后文件恢复为信号。身份归属先匹配账号库，无法匹配时用官方 profile 核验，不只相信缓存。
- 切换记录：`~/Library/Application Support/Lilt/switches.log`，最近 200 条：每次切换的时间和方式（手动或自动接力），以及切换或接管没成功时 Lilt 给出的原因，不含账号名称或凭据。会话里出现 “Connection lost mid-response” 之类的错误时，可以拿来对照是不是刚好在切换。
- 实时额度（默认开，可在“接入”页关闭）：在 `~/.claude/settings.json` 的状态栏命令前加一个小脚本，只取 Claude Code 交给状态栏的额度数据，终端里显示的内容不变。每次上报单独写成 `live-usage-spool/` 里的一个文件，几个会话同时上报不会互相覆盖；Lilt 每秒取走一次，不受额度查询、切换或钥匙串等待影响。最多保留 512 条，溢出或读不懂的会标成“采样有空洞”并改为主动查询，缺的部分按未知处理。第一次改动前会把原文件备份为 `claude-settings-before-lilt.json`，关闭时放回原来的状态栏。项目有各自的状态栏脚本和备份，只改项目自己的配置。
- 额度查询有节制：会话在持续上报时以上报为准，不额外查询。自动接力开着、一分钟内没有上报时，当前账号每 30 秒查一次（离阈值 15 个百分点以内时每 15 秒）；自动接力关着时 5 到 15 分钟一次。同一账号的查询合并成一次，不同账号的查询之间至少隔 2 秒。其他账号只在需要接力或手动刷新时才查：按预计到阈值的时间提前查首选和一个备选（没有消耗速度时，读数超过 5 分钟才查）；换号前查要换上的账号（2 分钟内查过的直接用），一次最多 4 个；额度已用完的账号在重置前不再重复查。项目账号只在一段时间没有上报时低频查询。遇到限流时全部暂停，手动刷新也不越过，等官方允许再查。
- `switches.log` 还会记下自动接力的触发原因（阈值或消耗速度）、读数年龄、候选确认和写入耗时，以及状态栏事件缺失，只有数字，没有账号信息。
- 更新时下载的安装包放在系统临时目录，装好或放弃后删除。
- 不修改 shell 配置、网络或代理设置。

## 从源码构建

需要 macOS 26+ 与 Swift 6.2+。唯一的第三方依赖是 Apple 的 [swift-crypto](https://github.com/apple/swift-crypto)（锁定 4.5.2），只用于账号迁移文件的 scrypt 与 AES-GCM，macOS 和 Linux 共用。Command Line Tools 就够；装有 Xcode 时会顺带编译强调色资源。

```sh
swift run LiltChecks          # 规则检查
bash scripts/check-relay-model.sh   # macOS 模型检查（隔离 HOME）
./scripts/build-app.sh        # 生成 build/Lilt.app（本机架构）
open build/Lilt.app
```

`./scripts/package.sh` 生成 Apple 芯片与 Intel 通用版本，并打成 `build/Lilt-<版本>.dmg`，需要装有 Xcode。

Logo、透明 PNG、SVG 和 App Icon 预览在 [`assets/brand`](assets/brand)。设计与重新生成方法见[品牌资产说明](assets/brand/README.md)。

## Agent Skill

仓库附带项目 Skill：[`.agents/skills/lilt/SKILL.md`](.agents/skills/lilt/SKILL.md)。它包含项目边界、代码结构、macOS/Linux 检查、SSH 安装运维、凭据安全和真实验收规则。支持项目级技能的 agent 可以直接使用；也可以把该目录复制到 `~/.agents/skills/lilt`，作为用户级 Skill。

## 许可

[MIT](LICENSE)。Lilt 是个人项目，不是 Anthropic 官方产品，与 Anthropic 没有关联。
