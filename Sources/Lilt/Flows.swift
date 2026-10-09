import SwiftUI
import LiltCore

struct AddAccountView: View {
    @Bindable var model: AppModel
    let request: AddRequest
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AuthKind
    @State private var label = ""
    @State private var token = ""
    @State private var code = ""
    @State private var saving = false
    @State private var failure: String?
    init(model: AppModel, request: AddRequest) {
        _model = Bindable(model); self.request = request; _kind = State(initialValue: request.kind)
    }
    private var target: Account? { request.replacing.flatMap { id in model.accounts.first { $0.id == id } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let target { Sprite(slot: model.spriteSlot(target.id), size: 34) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(target == nil ? "添加账号" : "更新授权").font(.system(size: 20, weight: .semibold))
                    if let target { Text("“\(target.label)” · 备注保持不变").font(Typo.caption).foregroundStyle(Tokens.muted) }
                }
            }
            Picker("授权方式", selection: $kind) { ForEach(AuthKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().disabled(model.loggingIn)
            if kind == .oauth {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在浏览器里用官方 Claude Code 登录，凭据存入本机钥匙串。")
                        .font(Typo.body).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                    if model.loggingIn {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("等待浏览器授权，最多 3 分钟…").font(Typo.caption) }
                        HStack(spacing: 8) {
                            SecureField("如浏览器给了授权码，在此输入", text: $code).textFieldStyle(.roundedBorder).onSubmit(submitCode)
                            Button("提交", action: submitCode).buttonStyle(.lilt(.secondary, size: .small)).disabled(code.isEmpty)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("粘贴 OAuth Token", text: $token).textFieldStyle(.roundedBorder)
                    Text("在终端运行 \(Text("claude setup-token").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.ink)) 获取。长效 Token 的额度查询和热切换可能受限，保存不代表验证通过。")
                        .font(Typo.caption).foregroundStyle(Tokens.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if target == nil { TextField("备注（可选），例如：日常创作", text: $label).textFieldStyle(.roundedBorder).disabled(model.loggingIn) }
            if let failure { InlineNote(text: failure) }
            HStack(spacing: 8) {
                Label("不收集密码，不发送模型请求", systemImage: "lock.shield").font(Typo.caption).foregroundStyle(Tokens.muted)
                Spacer()
                Button(model.loggingIn ? "取消授权" : "取消") { model.login.cancel(); if !model.loggingIn { token = ""; dismiss() } }
                    .buttonStyle(.lilt(.ghost)).keyboardShortcut(.cancelAction)
                Button(kind == .oauth ? "打开浏览器" : "保存 Token") {
                    saving = true; failure = nil
                    Task {
                        let error = kind == .oauth ? await model.browserLogin(label: label, replacing: request.replacing)
                                                   : await model.addToken(label: label, token: token, replacing: request.replacing)
                        token = ""; code = ""; saving = false
                        if let error { failure = error } else { dismiss() }
                    }
                }
                .buttonStyle(.lilt(.primary)).keyboardShortcut(.defaultAction)
                .disabled(saving || model.loggingIn || (kind == .setupToken && token.isEmpty) || !model.canAdd)
            }
        }
        .padding(24).frame(width: 440).tint(Tokens.accentTint)
        .interactiveDismissDisabled(model.loggingIn)
        .onDisappear { token = ""; code = ""; if model.loggingIn { model.login.cancel() } }
    }
    private func submitCode() {
        guard !code.isEmpty else { return }
        model.login.submitCode(code); code = ""
    }
}
extension View {
    /// One confirmation for enabling the scope, wherever the user starts it from.
    func scopeConfirmation(_ isPresented: Binding<Bool>, model: AppModel) -> some View {
        confirmationDialog("启用 Lilt 专属作用域？", isPresented: isPresented, titleVisibility: .visible) {
            Button("启用") { model.enableScope() }
            Button("取消", role: .cancel) {}
        } message: { Text("用启动命令打开的所有 CLI 会话共享这里的凭据，切换账号可能一起影响它们。现有 ORCA 与 ~/.claude 不会被导入或覆盖。") }
    }
}
/// First run, one step at a time: the card only ever shows the next thing to do.
/// The four steps are what has to happen, in order, before Claude Code runs under an account Lilt manages.
struct SetupCard: View {
    @Bindable var model: AppModel
    static let handledKey = "setup.launchCommandHandled"
    /// Lilt cannot observe the CLI being launched, so the last step ends when the command has been copied or put off.
    @AppStorage(SetupCard.handledKey) private var launchHandled = false
    @State private var confirmingScope = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Step: Int { case account, scope, choose, launch }
    private var step: Step? {
        if model.accounts.isEmpty { return .account }
        if !model.library.preferences.scopeEnabled { return .scope }
        if model.active == nil { return .choose }
        return launchHandled ? nil : .launch
    }
    var body: some View {
        VStack(spacing: 0) {
            if let step {
                VStack(spacing: 18) {
                    content(step).id(step).transition(.liltHandoff(reduceMotion: reduceMotion))
                    StepDots(count: 4, current: step.rawValue)
                }
                .padding(.vertical, 34).padding(.horizontal, 28).frame(maxWidth: .infinity).object()
                .transition(.liltReveal(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: step)
        .scopeConfirmation($confirmingScope, model: model)
    }
    @ViewBuilder private func content(_ step: Step) -> some View {
        switch step {
        case .account:
            stage("person.crop.circle.badge.plus", "添加第一个账号", "用官方 Claude Code 登录，凭据只存在本机") {
                HStack(spacing: 8) {
                    Button("登录添加") { model.requestAdd(.oauth) }.buttonStyle(.lilt(.primary, size: .large))
                    Button("粘贴 Token") { model.requestAdd(.setupToken) }.buttonStyle(.lilt(.secondary, size: .large))
                }.disabled(!model.canAdd)
                Button("先看看演示") { model.startDemo() }.buttonStyle(.lilt(.ghost, size: .small))
            }
        case .scope:
            stage("lock.shield", "启用 Lilt 作用域", "Lilt 只管理自己的目录，不动 ORCA 和 ~/.claude") {
                Button("启用…") { confirmingScope = true }.buttonStyle(.lilt(.primary, size: .large))
            }
        case .choose:
            stage("arrow.left.arrow.right", "选一个账号开始", "把它的凭据写入 Lilt 作用域") {
                if let first = model.accounts.first(where: \.enabled) {
                    Button("切换到“\(first.label)”") { Task { await model.apply(first.id) } }
                        .buttonStyle(.lilt(.primary, size: .large)).disabled(model.busy || model.loading)
                }
            }
        case .launch:
            stage("terminal", "用这条命令启动 Claude Code", "在终端运行，之后用 /status 核对账号") {
                CommandBlock(display: model.runtime.launchCommandDisplay, command: model.runtime.launchCommand) {
                    // Leave the "copied" mark on screen long enough to be seen before the card goes.
                    Task { try? await Task.sleep(for: .seconds(1.4)); launchHandled = true }
                }
                .frame(maxWidth: 480)
                Button("以后再说") { launchHandled = true }.buttonStyle(.lilt(.ghost, size: .small))
                    .help("启动命令随时可以在“作用域”页找到")
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
struct ScopeView: View {
    @Bindable var model: AppModel
    @State private var confirming = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var enabled: Bool { model.library.preferences.scopeEnabled }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "terminal").font(.system(size: 15, weight: .medium)).foregroundStyle(Tokens.ink)
                        .frame(width: 36, height: 36).background(Tokens.fill, in: Circle()).accessibilityHidden(true)
                    Text("Lilt 作用域").font(Typo.title)
                    Spacer()
                    if enabled { Pill(text: "已启用", symbol: "checkmark", style: .soft(.success)) }
                    else {
                        Button("启用…") { confirming = true }.buttonStyle(.lilt(.primary)).disabled(model.demo)
                            .help(model.demo ? "演示模式下不能启用，退出演示后再操作。" : "启用 Lilt 专属作用域")
                    }
                }
                CommandBlock(display: model.runtime.launchCommandDisplay, command: model.runtime.launchCommand)
                Text("用这条命令启动的 CLI 才归 Lilt 管。先切换到一个账号再运行；命令里没有凭据。")
                    .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24).object()
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
                        note("rectangle.on.rectangle", "作用域里的会话共享凭据，切换可能一起影响它们。首次接入请用一个受控的前台会话。")
                        note("lock.shield", "现有 ORCA 与默认 ~/.claude 不会被导入或覆盖。固定 Token 环境变量会阻止热切换；启动命令会清除常见的认证覆盖项。")
                        note("hourglass", "凭据写入成功不等于后续请求身份已切换。切换或自动接力之后，在 CLI 里用 /status 核对。")
                        note("pause.circle", "检测到外部修改时，Lilt 暂停并保留现场；本预览版不自动恢复事务，也不终止或重放 CLI 指令。")
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                    .transition(.liltReveal(reduceMotion: reduceMotion))
                }
            }
            .object()
            // Accordion timing from the Image accordion block.
            .animation(reduceMotion ? Motion.fade : Motion.expoOut(), value: expanded)
        }
        .scopeConfirmation($confirming, model: model)
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
    private var threshold: Binding<Double> { Binding(get: { model.threshold }, set: { model.setThreshold($0) }) }
    private var shortcut: Binding<UInt32> {
        Binding(get: { model.library.preferences.shortcutKey }, set: { model.setShortcut($0); AppDelegate.shared?.registerShortcut() })
    }
    var body: some View {
        Form {
            Section {
                LabeledContent("接力阈值") {
                    HStack(spacing: 6) {
                        TextField("接力阈值", value: threshold, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 56)
                        Text("%").foregroundStyle(.secondary)
                        Stepper("接力阈值", value: threshold, in: 0...20, step: 0.5).labelsHidden()
                    }
                }
            } footer: { Text("默认 1%，可设 0–20%。任一有效窗口的剩余额度达到阈值即触发；未知额度不作为可用候选。") }
            Section {
                Picker("快速面板快捷键", selection: shortcut) { Text("⌘⌥L").tag(UInt32(37)); Text("⌘⌥J").tag(UInt32(38)); Text("⌘⌥K").tag(UInt32(40)) }
                if let issue = model.shortcutIssue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tone.warning.text) }
            } footer: { Text("在任何应用里按下，打开或收起菜单栏面板。Lilt 无法得知其他应用是否占用了同一组合；按下没有反应时请换一个。") }
            Section {
                LabeledContent("版本", value: "0.1 · 研究预览版")
            } footer: { Text("运行中的 CLI 是否即时换号、刷新竞争、多会话及跨账号缓存尚待验证。") }
        }.formStyle(.grouped).tint(Tokens.accentTint)
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
                    UsageMeter(title: "5 小时", window: active.usage?.fiveHour, snapshot: active.usage, threshold: model.threshold, unreadable: unreadable, compact: true)
                    UsageMeter(title: "7 天", window: active.usage?.sevenDay, snapshot: active.usage, threshold: model.threshold, unreadable: unreadable, compact: true)
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
            if !model.accounts.isEmpty {
                ScrollView(.horizontal) {
                    // The panel cannot show the alert or page a refused switch leads to, so it opens the window instead.
                    RunnerTrack(runners: model.runners, activeID: model.library.activeID, orbSize: 34, disabled: model.busy || model.loading,
                                onSelect: { id in Task { if !(await model.apply(id)) { openMain() } } })
                        .padding(.horizontal, 2).padding(.top, 4)
                }
                .scrollIndicators(.hidden)
            }
            HStack {
                let blocker = model.autoRelay ? nil : model.relayBlocker
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动接力").font(Typo.label)
                    if let blocker { Text(blocker).font(Typo.caption).foregroundStyle(Tokens.muted) }
                }
                .help("剩余 ≤\(model.threshold.formatted())% 时换下一个")
                Spacer()
                LiquidToggle(label: "自动接力", isOn: Binding(get: { model.autoRelay }, set: { model.setAutoRelay($0) }), width: 44)
                    .disabled(blocker != nil).accessibilityHint(blocker ?? "")
            }
            HStack(spacing: 2) {
                Button("管理账号") { model.selectedPage = .accounts; openMain() }.buttonStyle(.lilt(.ghost, size: .small))
                Spacer()
                Button { refreshSpin += 1; if let id = model.active?.id { Task { await model.refresh(id) } } } label: {
                    Image(systemName: "arrow.clockwise").symbolEffect(.rotate, value: reduceMotion ? 0 : refreshSpin)
                }
                .buttonStyle(.liltIcon(.ghost, diameter: 28)).disabled(model.active == nil || model.loading || model.busy)
                .help("刷新额度").accessibilityLabel("刷新额度")
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.liltIcon(.ghost, diameter: 28)).help("设置").accessibilityLabel("设置")
                Menu { Button("退出 Lilt") { NSApp.terminate(nil) } } label: {
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
    }
    private func openMain() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
