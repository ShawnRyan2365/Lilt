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
                    Text("在浏览器里用官方 Claude Code 登录，凭据只保存在这台 Mac 上，仅当前用户可读。")
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
            // Swapping a full login for a long-lived token is a downgrade; say what is lost before it happens.
            if let target, target.kind == .oauth, kind == .setupToken {
                InlineNote(text: "“\(target.label)”现在是浏览器登录。换成长效 Token 后，它将看不到额度，也不能参与自动接力。")
            }
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
            stage("terminal", "接管 Claude Code 默认登录", "之后在任何终端直接运行 claude，用的都是这里选中的账号") {
                Button("接管…") { orcaActive = OrcaProbe.managesDefaultLogin(); confirming = true }
                    .buttonStyle(.lilt(.primary, size: .large)).disabled(model.busy)
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
                    note("lock.shield", "设置了 CLAUDE_CODE_OAUTH_TOKEN、ANTHROPIC_API_KEY 或 CLAUDE_CONFIG_DIR 的终端不走默认登录，Lilt 管不到。")
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
                LabeledContent("先用快重置的周额度") {
                    LiquidToggle(label: "先用快重置的周额度", isOn: Binding(get: { model.soonerWeekly }, set: { model.setSoonerWeekly($0) }), width: 44)
                }
            } footer: { Text("这是可选策略，默认关闭，会在当前账号还有额度时提前换走，从而多付一次缓存写入。") }
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
                    UsageMeter(kind: .fiveHour, snapshot: active.usage, threshold: model.threshold, unreadable: unreadable, compact: true)
                    UsageMeter(kind: .sevenDay, snapshot: active.usage, threshold: model.threshold, unreadable: unreadable, compact: true)
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
                    RunnerTrack(runners: model.runners, activeID: model.library.activeID, orbSize: 30, disabled: model.busy || model.loading,
                                onSelect: { id in Task { if !(await model.apply(id)) { openMain() } } })
                        .padding(.horizontal, 2).padding(.top, 4)
                }
                .scrollIndicators(.never)
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
