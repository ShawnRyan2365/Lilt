import SwiftUI
import UniformTypeIdentifiers
import LiltCore

struct AddAccountView: View {
    /// How the login is obtained. Saving the current login or importing a file is a way in, not a kind of account.
    private enum Method: CaseIterable {
        case browser, token, current, credential
        var title: String {
            switch self {
            case .browser: AuthKind.oauth.title
            case .token: AuthKind.setupToken.title
            case .current: "当前登录"
            case .credential: "导入凭证"
            }
        }
    }
    @Bindable var model: AppModel
    let request: AddRequest
    @Environment(\.dismiss) private var dismiss
    @State private var method: Method
    @State private var label = ""
    @State private var token = ""
    @State private var code = ""
    @State private var credentialFile: URL?
    @State private var saving = false
    @State private var failure: String?
    init(model: AppModel, request: AddRequest) {
        let initial: Method = request.credential && request.replacing == nil ? .credential : request.current && request.replacing == nil ? .current : request.kind == .oauth ? .browser : .token
        _model = Bindable(model); self.request = request; _method = State(initialValue: initial)
    }
    private var target: Account? { request.replacing.flatMap { id in model.accounts.first { $0.id == id } } }
    /// Updating one account's authorization asks for a new login of it; whatever happens to be current is another matter.
    private var methods: [Method] { target == nil ? Method.allCases : [.browser, .token, .credential] }
    private var saveTitle: String {
        switch method {
        case .browser: "获取授权链接"
        case .token: "保存 Token"
        case .current: "保存当前登录"
        case .credential: "导入凭证"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let target { Sprite(slot: model.spriteSlot(target.id), size: 34) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(target == nil ? "添加账号" : "更新授权").font(.system(size: 20, weight: .semibold))
                    if let target { Text("“\(target.label)” · 备注保持不变").font(Typo.caption).foregroundStyle(Tokens.muted) }
                }
            }
            Picker("授权方式", selection: $method) { ForEach(methods, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().disabled(model.loggingIn || saving)
            switch method {
            case .browser:
                VStack(alignment: .leading, spacing: 10) {
                    Text("用官方 Claude Code 登录。先拿到授权链接，再选在哪个浏览器打开；凭据只保存在这台 Mac 上，仅当前用户可读。")
                        .font(Typo.body).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                    if model.loggingIn {
                        if let link = model.loginLink {
                            LoginLinkBox(link: link)
                            Text("登录要保存的那个账号，授权后网页会给一串授权码，粘贴到下面。最多等 3 分钟。")
                                .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在向官方 CLI 要授权链接…").font(Typo.caption) }
                        }
                        HStack(spacing: 8) {
                            SecureField("粘贴网页给的授权码", text: $code).textFieldStyle(.roundedBorder).onSubmit(submitCode)
                            Button("提交", action: submitCode).buttonStyle(.lilt(.secondary, size: .small)).disabled(code.isEmpty)
                        }
                    }
                }
            case .current:
                VStack(alignment: .leading, spacing: 8) {
                    Text("把这台 Mac 上 Claude Code 正在用的登录存进 Lilt，就是终端里 \(Text("/\u{2060}login").font(.system(size: 12, design: .monospaced)).foregroundStyle(Tokens.ink)) 登进去的那个账号。")
                        .font(Typo.body).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                    if model.managesDefaultLogin {
                        Text("Lilt 正在管理默认登录：保存后它就是正在使用的账号。Lilt 里已有的同一个账号只更新授权，不重复添加。")
                            .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                    } else {
                        InlineNote(text: "Lilt 还没接管默认登录，存进来的是一份副本，和终端共用同一个续期凭据。以后哪边先续期，另一边就要重新登录。想避免，先接管默认登录。")
                    }
                }
            case .token:
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("粘贴 OAuth Token", text: $token).textFieldStyle(.roundedBorder)
                    Text("在终端运行 \(Text("claude setup-token").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.ink)) 获取。长效 Token 的额度查询和热切换可能受限，保存不代表验证通过。")
                        .font(Typo.caption).foregroundStyle(Tokens.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            case .credential:
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择官方 .credentials.json，或含 credentials 的账号 JSON。会转换为完整 OAuth 登录；备注留空时使用文件内的名称或文件名。")
                        .font(Typo.body).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(credentialFile == nil ? "选择 JSON 文件…" : "重新选择…", action: chooseCredentialFile)
                            .buttonStyle(.lilt(.secondary, size: .small)).disabled(saving)
                        if let credentialFile {
                            Label(credentialFile.lastPathComponent, systemImage: "checkmark.circle.fill")
                                .font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    InlineNote(text: target == nil
                               ? "只保存到 Lilt，不切换当前账号。Lilt 后续会续期这份登录；其他使用同一凭据的副本可能需要重新登录。"
                               : "替换这个账号保存的登录；若它正在使用或固定给项目，Lilt 会同步新授权。其他使用同一凭据的副本可能需要重新登录。")
                }
            }
            if target == nil { TextField("备注（可选），例如：日常创作", text: $label).textFieldStyle(.roundedBorder).disabled(model.loggingIn || saving) }
            // Swapping a full login for a long-lived token is a downgrade; say what is lost before it happens.
            if let target, target.kind == .oauth, method == .token {
                InlineNote(text: "“\(target.label)”现在是浏览器登录。换成长效 Token 后，它将看不到额度，也不能参与自动接力。")
            }
            if let failure { InlineNote(text: failure) }
            HStack(spacing: 8) {
                Label("不收集密码，不发送模型请求", systemImage: "lock.shield").font(Typo.caption).foregroundStyle(Tokens.muted)
                Spacer()
                Button(model.loggingIn ? "取消授权" : "取消") { model.login.cancel(); if !model.loggingIn { token = ""; dismiss() } }
                    .buttonStyle(.lilt(.ghost)).keyboardShortcut(.cancelAction)
                Button(saveTitle) {
                    saving = true; failure = nil
                    Task {
                        let error = switch method {
                        case .browser: await model.browserLogin(label: label, replacing: request.replacing)
                        case .token: await model.addToken(label: label, token: token, replacing: request.replacing)
                        case .current: await model.saveCurrentLogin(label: label)
                        case .credential:
                            if let credentialFile {
                                await model.importOAuthCredential(from: credentialFile, label: label, replacing: request.replacing)
                            } else {
                                "请先选择登录凭证 JSON 文件。"
                            }
                        }
                        token = ""; code = ""; credentialFile = nil; saving = false
                        if let error { failure = error } else { dismiss() }
                    }
                }
                .buttonStyle(.lilt(.primary)).keyboardShortcut(.defaultAction)
                .disabled(saving || model.loggingIn || (method == .token && token.isEmpty) || (method == .credential && credentialFile == nil) || !model.canAdd)
            }
        }
        .padding(24).frame(width: 480).tint(Tokens.accentTint)
        .interactiveDismissDisabled(model.loggingIn || saving)
        .onDisappear { token = ""; code = ""; credentialFile = nil; if model.loggingIn { model.login.cancel() } }
    }
    private func submitCode() {
        guard !code.isEmpty else { return }
        model.login.submitCode(code); code = ""
    }
    private func chooseCredentialFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "选择凭证"
        panel.message = "选择官方 .credentials.json，或含完整 OAuth credentials 的账号 JSON 文件。"
        if panel.runModal() == .OK { credentialFile = panel.url }
    }
}
/// The sign-in link the official CLI printed, with the two things to do with it: open it here, or copy it into a
/// browser that is signed in to the account wanted. The link is only shown; nothing writes it down.
private struct LoginLinkBox: View {
    let link: URL
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(link.absoluteString)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.ink)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("在默认浏览器打开") { NSWorkspace.shared.open(link) }.buttonStyle(.lilt(.primary, size: .small))
                Button(copied ? "已拷贝" : "拷贝链接") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    copied = true
                }
                .buttonStyle(.lilt(.secondary, size: .small))
                Spacer()
            }
        }
        .padding(10).background(Tokens.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
    }
}
extension View {
    /// One confirmation for taking over Claude Code's default login, wherever the user starts it from.
    func takeoverConfirmation(_ isPresented: Binding<Bool>, model: AppModel, orcaActive: Bool) -> some View {
        confirmationDialog("让 Lilt 接管 Claude Code 默认登录？", isPresented: isPresented, titleVisibility: .visible) {
            Button("接管") { Task { await model.takeOverDefaultLogin() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后在任何终端直接运行 claude，用的都是 Lilt 里选中的账号，正在运行的会话也会一起换。现在登录着的账号会加入 Lilt，不会被退出。"
                 + (orcaActive ? "\n\nORCA 现在也在切换这个登录。接管后请在 ORCA 里停用 Claude 账号切换，否则两边会互相覆盖。" : ""))
        }
    }
}
/// First run, one step at a time: the card only ever shows the next thing to do.
struct SetupCard: View {
    @Bindable var model: AppModel
    @State private var confirming = false
    @State private var orcaActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Step: Int, CaseIterable { case takeover, account, choose }
    private var step: Step? {
        if !model.managesDefaultLogin, !model.projectCatalog.projects.isEmpty { return nil }
        if !model.managesDefaultLogin { return .takeover }
        if model.accounts.isEmpty { return .account }
        return model.active == nil ? .choose : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            if let step {
                VStack(spacing: 18) {
                    content(step).id(step).transition(.liltHandoff(reduceMotion: reduceMotion))
                    StepDots(count: Step.allCases.count, current: step.rawValue)
                }
                .padding(.vertical, 34).padding(.horizontal, 28).frame(maxWidth: .infinity).object()
                .transition(.liltReveal(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: step)
        .takeoverConfirmation($confirming, model: model, orcaActive: orcaActive)
    }
    @ViewBuilder private func content(_ step: Step) -> some View {
        switch step {
        case .takeover:
            stage("terminal", "选择 Claude Code 使用方式", "接管默认登录让所有终端共享接力；按项目隔离则各自固定账号") {
                HStack(spacing: 8) {
                    Button("接管默认登录…") { orcaActive = OrcaProbe.managesDefaultLogin(); confirming = true }
                        .buttonStyle(.lilt(.primary, size: .large)).disabled(model.busy)
                    Button("按项目隔离") { model.selectedPage = .projects }
                        .buttonStyle(.lilt(.secondary, size: .large))
                }
                if model.accounts.isEmpty { Button("先看看演示") { model.startDemo() }.buttonStyle(.lilt(.ghost, size: .small)) }
            }
        case .account:
            stage("person.crop.circle.badge.plus", "添加第一个账号", "用官方 Claude Code 登录，凭据只存在本机") {
                HStack(spacing: 8) {
                    Button("登录添加") { model.requestAdd(.oauth) }.buttonStyle(.lilt(.primary, size: .large))
                    Button("粘贴 Token") { model.requestAdd(.setupToken) }.buttonStyle(.lilt(.secondary, size: .large))
                }.disabled(!model.canAdd)
            }
        case .choose:
            stage("arrow.left.arrow.right", "选一个账号开始", "终端里的 claude 会用这个账号") {
                if let first = model.accounts.first(where: \.enabled) {
                    Button("切换到“\(first.label)”") { Task { await model.apply(first.id) } }
                        .buttonStyle(.lilt(.primary, size: .large)).disabled(model.busy || model.loading)
                }
            }
        }
    }
    private func stage<Actions: View>(_ symbol: String, _ title: String, _ hint: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Tokens.ink)
                .frame(width: 52, height: 52).background(Tokens.fill, in: Circle()).accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
                Text(hint).font(Typo.body).foregroundStyle(Tokens.muted).multilineTextAlignment(.center)
            }
            actions()
        }
    }
}
/// Where Lilt puts the selected login, and how to change that.
struct ScopeView: View {
    @Bindable var model: AppModel
    @State private var confirming = false
    @State private var expanded = false
    @State private var orcaActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            defaultLoginCard
            if model.scopeTarget == .dedicated && model.library.preferences.scopeEnabled { dedicatedCard }
            notes
        }
        .takeoverConfirmation($confirming, model: model, orcaActive: orcaActive)
        .onAppear { orcaActive = OrcaProbe.managesDefaultLogin() }
    }
    private var defaultLoginCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "terminal").font(.system(size: 15, weight: .medium)).foregroundStyle(Tokens.ink)
                    .frame(width: 36, height: 36).background(Tokens.fill, in: Circle()).accessibilityHidden(true)
                Text("Claude Code 默认登录").font(Typo.title)
                Spacer()
                if model.managesDefaultLogin { Pill(text: "由 Lilt 管理", symbol: "checkmark", style: .soft(.success)) }
                else {
                    Button("接管…") { orcaActive = OrcaProbe.managesDefaultLogin(); confirming = true }
                        .buttonStyle(.lilt(.primary)).disabled(model.demo || model.busy)
                        .help(model.demo ? "演示模式下不能接管，退出演示后再操作。" : "让 Lilt 管理 Claude Code 默认登录")
                }
            }
            Text(model.managesDefaultLogin ? "在任何终端直接运行 claude，用的都是 Lilt 里选中的账号。"
                                           : "接管后，在任何终端直接运行 claude，用的都是 Lilt 里选中的账号，不需要特别的启动命令。")
                .font(Typo.body).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
            Text("运行时登录只以 macOS 钥匙串为准；`.credentials.json` 仅用于提醒 Claude Code 重新读取。若文件中也出现另一份有效登录，Lilt 会暂停切换并要求处理。")
                .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
            if model.dualConflict {
                Button("处理双登录冲突") { model.confirmingDual = true }.buttonStyle(.lilt(.secondary)).disabled(model.busy)
            }
            if orcaActive {
                InlineNote(text: "ORCA 也在切换这个登录。两边同时管理会互相覆盖：请在 ORCA 里停用 Claude 账号切换，只留一个。")
            }
            if model.managesDefaultLogin {
                liveUsageRow
                Button("停止接管") { model.releaseDefaultLogin() }.buttonStyle(.lilt(.ghost, size: .small)).padding(.leading, -11)
                    .help("Lilt 不再改动默认登录；现在登录着的账号保持不变")
            }
        }
        .padding(24).object()
    }
    /// Live quota from Claude Code's status line: on or off, and whether readings are arriving.
    private var liveUsageRow: some View {
        let _ = model.clock // the age below moves with the monitor
        let caption: String = {
            guard model.liveUsageEnabled else { return "关闭时每几分钟问一次额度接口。" }
            if let issue = model.statusLineIssue { return issue }
            if let at = model.liveUsageSampledAt { return "Claude Code 每次回复后更新 · 最近一次\(Wording.age(at, now: .now).replacingOccurrences(of: "更新", with: ""))" }
            return "已接上。下次 Claude Code 回复后就有读数；原来的状态栏照常显示。"
        }()
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("实时额度").font(Typo.label)
                Text(caption).font(Typo.caption).foregroundStyle(model.statusLineIssue == nil ? AnyShapeStyle(Tokens.muted) : Tone.warning.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            LiquidToggle(label: "从 Claude Code 状态栏读取额度", isOn: Binding(get: { model.liveUsageEnabled }, set: { model.setLiveUsage($0) }), width: 44)
        }
        .padding(14).well()
        .help("Lilt 在 ~/.claude/settings.json 的状态栏命令前加一个小脚本，只取额度，再交给原来的命令。关闭后放回原样。")
    }
    /// Setups made before Lilt could take over the default login keep working until the user moves on.
    private var dedicatedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lilt 专属作用域").font(Typo.label)
                Spacer()
                Pill(text: "旧的接入方式")
            }
            Text("目前只有用这条命令启动的终端会用 Lilt 选中的账号。接管默认登录后就不需要它了。")
                .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
            CommandBlock(display: model.runtime.launchCommandDisplay, command: model.runtime.launchCommand)
        }
        .padding(20).object()
    }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text("切换前要知道的").font(Typo.label)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tokens.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 20).padding(.vertical, 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "收起" : "展开")
            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    note("rectangle.on.rectangle", "所有使用默认登录的 Claude Code 会话共用一个账号，切换会一起影响它们，包括正在运行的。")
                    note("lock.shield", "从 CC Switch 切到 API 后，可保留 API，也可点订阅账号切回。终端启动时固定的环境变量或自定义配置目录需单独处理。")
                    note("hourglass", "已经发出的请求仍算在原账号上。切换后可以在 CLI 里用 /status 核对。")
                    note("pause.circle", "发现默认登录被别处改了（例如 ORCA 或 /login），Lilt 会暂停自动接力，等你决定采纳还是改回。")
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .transition(.liltReveal(reduceMotion: reduceMotion))
            }
        }
        .object()
        // Accordion timing from the Image accordion block.
        .animation(reduceMotion ? Motion.fade : Motion.expoOut(), value: expanded)
    }
    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.muted).frame(width: 18).accessibilityHidden(true)
            Text(text).font(Typo.body).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var transfer: CredentialTransferRequest?
    private var fiveHourThreshold: Binding<Double> { Binding(get: { model.thresholds.fiveHour }, set: { model.setFiveHourThreshold($0) }) }
    private var sevenDayThreshold: Binding<Double> { Binding(get: { model.thresholds.sevenDay }, set: { model.setSevenDayThreshold($0) }) }
    private var shortcut: Binding<UInt32> {
        Binding(get: { model.library.preferences.shortcutKey }, set: { model.setShortcut($0); AppDelegate.shared?.registerShortcut() })
    }
    var body: some View {
        Form {
            Section {
                thresholdRow("5 小时阈值", fiveHourThreshold)
                thresholdRow("7 天阈值", sevenDayThreshold)
            } footer: { Text("默认都是 1%，可设 0–20%。任一窗口剩余到阈值就换号；高并发下按实际消耗速度和接力耗时提前，不再固定封顶 10 点。未知额度不作为可用候选。") }
            Section {
                LabeledContent("先用快重置的周额度") {
                    LiquidToggle(label: "先用快重置的周额度", isOn: Binding(get: { model.soonerWeekly }, set: { model.setSoonerWeekly($0) }), width: 44)
                }
            } footer: { Text("这是可选策略，默认关闭，会在当前账号还有额度时提前换走，从而多付一次缓存写入。") }
            Section {
                LabeledContent("自动排序") {
                    LiquidToggle(label: "自动排序", isOn: Binding(get: { model.autoSort }, set: { model.setAutoSort($0) }), width: 44)
                }
            } footer: { Text("不限 7 天额度的账号（如企业版）排最前，换号时最先用；其余按 7 天额度排：先重置的在前，同一天重置的剩余多的在前。同一组里先挑 5 小时额度最空的，一样空的按这个顺序，换上后一直用到阈值。和「先用快重置的周额度」二选一，关闭后恢复手动顺序。") }
            Section {
                Picker("快速面板快捷键", selection: shortcut) { Text("⌘⌥L").tag(UInt32(37)); Text("⌘⌥J").tag(UInt32(38)); Text("⌘⌥K").tag(UInt32(40)) }
                if let issue = model.shortcutIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning.text) }
            } footer: { Text("在任何应用里按下，打开或收起菜单栏面板。Lilt 无法得知其他应用是否占用了同一组合；按下没有反应时请换一个。") }
            Section {
                Button("加密导出账号库…") {
                    if let url = CredentialTransferPanels.exportURL() { transfer = CredentialTransferRequest(mode: .export, url: url) }
                }
                .disabled(model.demo || model.accounts.isEmpty || model.busy || model.loggingIn)
                Button("导入账号库…") {
                    if let url = CredentialTransferPanels.importURL() { transfer = CredentialTransferRequest(mode: .import, url: url) }
                }
                .disabled(model.demo || model.busy || model.loggingIn)
            } header: { Text("账号迁移") }
            footer: { Text("口令加密的一次性迁移，不是云同步。导出文件含可登录凭据；导入只新增、默认停用并关闭自动接力，不改变当前 Claude 登录。") }
            Section {
                LabeledContent("版本", value: "\(AppBuild.version) · 研究预览版")
                LabeledContent("自动检查更新") {
                    LiquidToggle(label: "自动检查更新", isOn: Binding(get: { model.autoUpdateCheck }, set: { model.setAutoUpdateCheck($0) }), width: 44)
                }
                UpdateRow(model: model)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("每 6 小时向 GitHub 查一次新版本，请求里没有账号信息。更新时下载安装包，校验后替换现在的 Lilt 并重新打开，账号和设置都保留。")
                    Text("运行中的 CLI 是否即时换号、刷新竞争、多会话及跨账号缓存尚待验证。")
                }
            }
        }
        .formStyle(.grouped).tint(Tokens.accentTint)
        .sheet(item: $transfer) { CredentialTransferView(model: model, request: $0) }
    }
    private func thresholdRow(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 56)
                Text("%").foregroundStyle(.secondary)
                Stepper(title, value: value, in: 0...20, step: 0.5).labelsHidden()
            }
        }
    }
}
/// The menu bar panel: the same three things as the window, at a glance — who, how much, who next.
struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer = PointerTracker()
    @State private var refreshSpin = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if let active = model.active {
                    HStack(spacing: 10) {
                        Sprite(slot: model.spriteSlot(active.id), size: 30, mood: model.mood(of: active))
                        Text(active.label).font(Typo.heading).lineLimit(1)
                    }
                    .id(active.id).transition(.liltHandoff(reduceMotion: reduceMotion))
                    .accessibilityElement(children: .ignore).accessibilityLabel("当前账号：\(active.label)")
                } else {
                    Image(systemName: "waveform.path").font(.system(size: 17, weight: .semibold)).foregroundStyle(Tokens.accent).accessibilityHidden(true)
                    Text("Lilt").font(Typo.heading)
                }
                Spacer(minLength: 6)
                if model.demo { Pill(text: "演示", symbol: "play.fill", style: .ink) }
                Button { openMain() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.liltIcon(.ghost, diameter: 28)).help("打开管理窗口").accessibilityLabel("打开管理窗口")
            }
            if let active = model.active {
                HStack(alignment: .top, spacing: 20) {
                    let unreadable = active.usageCapability == .unavailable
                    UsageMeter(kind: .fiveHour, snapshot: active.usage, threshold: model.thresholds.fiveHour, unreadable: unreadable, compact: true)
                    UsageMeter(kind: .sevenDay, snapshot: active.usage, threshold: model.thresholds.sevenDay, unreadable: unreadable, compact: true)
                }
            } else if model.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("还没有账号").font(Typo.title)
                    HStack(spacing: 8) {
                        Button("登录添加") { model.requestAdd(.oauth); openMain() }.buttonStyle(.lilt(.primary))
                        Button("粘贴 Token") { model.requestAdd(.setupToken); openMain() }.buttonStyle(.lilt(.secondary))
                    }.disabled(!model.canAdd)
                }
            }
            NoticeIsland(model: model, onNeedsWindow: openMain)
            UpdateIsland(updater: model.updater, onInstall: model.installUpdate)
            if !model.accounts.isEmpty {
                ScrollView(.horizontal) {
                    // The panel cannot show the alert or page a refused switch leads to, so it opens the window instead.
                    RunnerTrack(runners: model.runners, activeID: model.displayedActiveID, orbSize: 30, disabled: model.busy,
                                onSelect: { id in Task { if !(await model.apply(id)) { openMain() } } })
                        .padding(.horizontal, 2).padding(.top, 4)
                }
                .scrollIndicators(.never)
            }
            HStack {
                let blocker = model.autoRelay ? nil : model.relayBlocker
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认登录 · 自动接力").font(Typo.label)
                    if let explanation = model.relayExplanation ?? blocker {
                        Text(explanation).font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(3).help(explanation)
                    }
                }
                .help(model.handOffRule)
                Spacer()
                LiquidToggle(label: "默认登录自动接力", isOn: Binding(get: { model.autoRelay }, set: { model.setAutoRelay($0) }), width: 44)
                    .disabled(blocker != nil).accessibilityHint(blocker ?? "")
            }
            HStack(spacing: 2) {
                Button("管理账号") { model.selectedPage = .accounts; openMain() }.buttonStyle(.lilt(.ghost, size: .small))
                Button("项目") { model.selectedPage = .projects; openMain() }.buttonStyle(.lilt(.ghost, size: .small))
                Spacer()
                Button { refreshSpin += 1; if let id = model.active?.id { Task { await model.refresh(id, manually: true) } } } label: {
                    Image(systemName: "arrow.clockwise").symbolEffect(.rotate, value: reduceMotion ? 0 : refreshSpin)
                }
                .buttonStyle(.liltIcon(.ghost, diameter: 28)).disabled(model.active == nil)
                .help("刷新额度").accessibilityLabel("刷新额度")
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.liltIcon(.ghost, diameter: 28)).help("设置").accessibilityLabel("设置")
                Menu {
                    Text(AppBuild.description)
                    Button("检查更新…") { model.checkForUpdates() }.disabled(model.updater.current == nil || model.updater.working)
                    Divider()
                    Button("退出 Lilt") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.ink).frame(width: 28, height: 28).contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("更多").accessibilityLabel("更多")
            }
            .padding(.leading, -8)
        }
        .padding(18).frame(width: 340).tint(Tokens.accentTint)
        .trackingPointer(pointer)
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: model.library.activeID)
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: model.notice())
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: model.updater.phase)
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: model.updater.reportsResult)
    }
    private func openMain() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
