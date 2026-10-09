import SwiftUI
import LiltCore

struct MainView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renameID: UUID?
    @State private var rename = ""
    @State private var deleteAccount: Account?
    @State private var statusToast = Transient()
    @State private var pointer = PointerTracker()
    @State private var refreshSpin = 0
    /// First-run steps are still open. The demo has nothing to set up.
    private var setupPending: Bool { !model.demo && (!model.managesDefaultLogin || !model.setupComplete) }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.demo { demoBar.transition(.liltReveal(reduceMotion: reduceMotion)) }
                NoticeIsland(model: model, hidesNoActive: setupPending && model.selectedPage == .overview).frame(maxWidth: 560)
                Group {
                    switch model.selectedPage {
                    case .overview: overview
                    case .accounts: accountsPage
                    case .scope: ScopeView(model: model)
                    case .diagnostics: diagnostics
                    }
                }
                .id(model.selectedPage).transition(.opacity)
            }
            .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : Motion.fade, value: model.selectedPage)
            .animation(reduceMotion ? Motion.fade : Motion.settle, value: model.demo)
            .animation(reduceMotion ? Motion.fade : Motion.settle, value: model.notice())
            .animation(reduceMotion ? Motion.fade : Motion.settle, value: setupPending)
        }
        .background { Rectangle().fill(Tokens.canvas).ignoresSafeArea() }
        .trackingPointer(pointer)
        // What used to sit in a status bar now appears for a moment, only when something happens.
        .toast(model.status, shown: statusToast.shown)
        .onChange(of: model.status) { _, status in
            statusToast.flash(for: 2.4)
            AccessibilityNotification.Announcement(status).post()
        }
        .onAppear { AppDelegate.shared?.presentMainWindow = { openWindow(id: "main") } }
        .tint(Tokens.accentTint)
        .frame(minWidth: 620, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("页面", selection: $model.selectedPage) {
                    ForEach(AppModel.Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            ToolbarItem { SettingsLink { Label("设置", systemImage: "gearshape") }.help("设置") }
            ToolbarItem {
                Button { model.requestAdd() } label: { Label("添加账号", systemImage: "plus") }
                    .disabled(!model.canAdd).help(model.demo ? "演示模式下不能添加账号" : "添加账号")
            }
        }
        .sheet(item: $model.addRequest) { AddAccountView(model: model, request: $0) }
        .alert("操作未完成", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) { Button("知道了") { model.message = nil } } message: { Text(model.message ?? "") }
        .alert("修改备注", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("账号备注", text: $rename)
            Button("取消", role: .cancel) { renameID = nil }
            Button("保存") { if let id = renameID, !rename.trimmingCharacters(in: .whitespaces).isEmpty { model.update(id) { $0.label = rename } }; renameID = nil }
        } message: { Text("备注只用于本机识别，不代表已验证的账号身份。") }
        .confirmationDialog(deleteAccount.map { "删除“\($0.label)”？" } ?? "删除账号？", isPresented: Binding(get: { deleteAccount != nil }, set: { if !$0 { deleteAccount = nil } }), titleVisibility: .visible) {
            Button("删除本地记录与凭据", role: .destructive) { if let account = deleteAccount { model.remove(account.id) }; deleteAccount = nil }
            Button("取消", role: .cancel) { deleteAccount = nil }
        } message: { Text("仅删除 Lilt 保存的资料；不会向官方撤销授权。") }
        .confirmationDialog("\(model.scopeName)里的登录不是 Lilt 写的那一份", isPresented: $model.confirmingAdopt, titleVisibility: .visible) {
            Button("仍是“\(model.active?.label ?? "")”，采纳它") { model.adoptScopeCredential() }
            Button("不是，改回“\(model.active?.label ?? "")”") { model.reclaimScope() }
            Button("取消", role: .cancel) {}
        } message: { Text("在终端运行 claude 后用 /status 看当前是谁。采纳：把现在的登录存为这个账号的，替换原来保存的那份。改回：用 Lilt 保存的那份覆盖现在的登录。") }
    }

    // MARK: Demo
    private var demoBar: some View {
        HStack(spacing: 10) {
            Pill(text: "演示", symbol: "play.fill", style: .ink)
            Text("账号和额度都是虚构的").font(Typo.caption).foregroundStyle(Tokens.muted)
            Spacer()
            Button("退出演示") { model.endDemo() }.buttonStyle(.lilt(.surface, size: .small))
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: Overview
    @ViewBuilder private var overview: some View {
        if setupPending { SetupCard(model: model).transition(.liltReveal(reduceMotion: reduceMotion)) }
        if let active = model.active { hero(active).staggeredAppear(index: 0) }
        if !model.accounts.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { track; relay.frame(width: 232) }.fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 14) { track; relay }
            }
            .staggeredAppear(index: 3)
        }
    }
    /// The account in use and how much it has left: the one thing this window is for.
    private func hero(_ active: Account) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Sprite(slot: model.spriteSlot(active.id), size: 40, mood: model.mood(of: active))
                    Text(active.label).font(Typo.title).lineLimit(1)
                }
                .id(active.id).transition(.liltHandoff(reduceMotion: reduceMotion))
                .accessibilityElement(children: .ignore).accessibilityLabel("当前账号：\(active.label)")
                Spacer(minLength: 8)
                if let usage = active.usage { FreshnessText(date: usage.sampledAt).font(Typo.caption).foregroundStyle(Tokens.muted) }
                Button { refreshSpin += 1; Task { await model.refresh(active.id) } } label: {
                    Image(systemName: "arrow.clockwise").symbolEffect(.rotate, value: reduceMotion ? 0 : refreshSpin)
                }
                .buttonStyle(.liltIcon(.filled)).disabled(model.loading || model.busy)
                .help("刷新额度").accessibilityLabel("刷新当前账号额度")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 36) { meters(active).frame(minWidth: 220) }
                VStack(alignment: .leading, spacing: 24) { meters(active) }
            }
        }
        .padding(24).object()
        .animation(reduceMotion ? Motion.fade : Motion.settle, value: active.id)
    }
    @ViewBuilder private func meters(_ active: Account) -> some View {
        let unreadable = active.usageCapability == .unavailable
        UsageMeter(title: "5 小时", window: active.usage?.fiveHour, snapshot: active.usage, threshold: model.threshold, unreadable: unreadable)
        UsageMeter(title: "7 天", window: active.usage?.sevenDay, snapshot: active.usage, threshold: model.threshold, unreadable: unreadable)
    }
    /// Who runs next. Left to right is relay order; pressing an orb passes the baton.
    private var track: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("接力顺序").font(Typo.caption).foregroundStyle(Tokens.muted)
                Spacer()
                Button("管理") { model.selectedPage = .accounts }.buttonStyle(.lilt(.ghost, size: .small))
                    .accessibilityLabel("管理账号")
            }
            // A row that fits is not a scroll view: macOS still draws a scrollbar when the preference is
            // “always”, and a row that barely overflows becomes a grey bar under the quota labels.
            ViewThatFits(in: .horizontal) {
                runnerTrack
                ScrollView(.horizontal) { runnerTrack }
                    .scrollIndicators(.never)
            }
        }
        .padding(.leading, 20).padding(.trailing, 12).padding(.top, 12).padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).object()
    }
    private var runnerTrack: some View {
        RunnerTrack(runners: model.runners, activeID: model.library.activeID, disabled: model.busy || model.loading,
                    onSelect: { id in Task { await model.apply(id) } },
                    onAdd: model.canAdd ? { model.requestAdd() } : nil) { runner in
            accountMenu(runner.id)
        }
        .padding(.horizontal, 2).padding(.top, 4).padding(.bottom, 2)
    }
    @ViewBuilder private func accountMenu(_ id: UUID) -> some View {
        if let account = model.accounts.first(where: { $0.id == id }) {
            let active = id == model.library.activeID
            Button("刷新额度") { Task { await model.refresh(id) } }
            Button("修改备注") { rename = account.label; renameID = id }
            Button(account.enabled ? "停用" : "启用") { model.update(id) { $0.enabled.toggle() } }
            Divider()
            Button("重新授权 / 替换 Token") { model.requestAdd(replacing: id) }.disabled(!model.canAdd)
            Button(active ? "删除（需先切换到其他账号）" : "删除…", role: .destructive) { deleteAccount = account }.disabled(active)
        }
    }
    private var relay: some View {
        // What still has to happen before it can be switched on, if anything.
        let blocker = model.autoRelay ? nil : model.relayBlocker
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("自动接力").font(Typo.label)
                Spacer()
                LiquidToggle(label: "自动接力", isOn: Binding(get: { model.autoRelay }, set: { model.setAutoRelay($0) }))
                    .disabled(blocker != nil).accessibilityHint(blocker ?? "")
            }
            Text(blocker ?? "剩余 ≤\(model.threshold.formatted())% 时换下一个")
                .font(Typo.caption).foregroundStyle(Tokens.muted)
            if model.demo || model.lastEvent != "尚无接力记录" {
                Spacer(minLength: 6)
                Text(model.lastEvent).font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(3)
                    .id(model.lastEvent).transition(.opacity)
            }
            if model.demo {
                Button("模拟到阈值") { Task { await model.simulateThreshold() } }.buttonStyle(.lilt(.secondary, size: .small))
                    .disabled(model.busy || model.loading)
            }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).object()
        .help(model.demo ? "" : "到阈值时，Lilt 把下一个账号的凭据写入作用域。运行中的 CLI 是否已用上新账号，请在 CLI 里用 /status 核对。")
        .animation(reduceMotion ? nil : Motion.fade, value: model.lastEvent)
    }

    // MARK: Accounts
    private var accountsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.accounts.isEmpty { EmptyAccounts(model: model) }
            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                AccountRow(model: model, account: account, index: index,
                           onRename: { rename = account.label; renameID = account.id }, onDelete: { deleteAccount = account })
                    .staggeredAppear(index: index * 2)
                    .draggable(account.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                        model.move(dragged, to: account.id); return true
                    }
            }
            if !model.accounts.isEmpty {
                Text("从上到下是接力顺序，可以拖动调整。备注只用于本机识别，本版不做账号去重。")
                    .font(Typo.caption).foregroundStyle(Tokens.muted).padding(.horizontal, 6).padding(.top, 4)
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: model.accounts.map(\.id))
    }

    // MARK: Diagnostics
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                fact("Claude Code", model.version.replacingOccurrences(of: " (Claude Code)", with: ""))
                fact("系统", "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)")
                fact("接入方式", !model.library.preferences.scopeEnabled ? "未接管" : model.scopeTarget == .system ? "Claude Code 默认登录" : "Lilt 专属目录")
                fact("实时额度", !model.managesDefaultLogin ? "未接管默认登录" : !model.liveUsageEnabled ? "关闭（按时查询接口）" : model.liveUsageSampledAt.map { "状态栏 · \(Wording.age($0, now: .now))" } ?? "状态栏 · 尚无读数")
                fact("模型转发", "无", last: true)
            }
            .padding(.horizontal, 20).padding(.vertical, 6).object()
            VStack(alignment: .leading, spacing: 12) {
                Text("尚未验证").font(Typo.caption).foregroundStyle(Tokens.muted)
                boundary("testtube.2", "阈值规则：可用本地演示验证")
                boundary("hourglass", "原进程热切换与后续请求身份：待实测")
                boundary("arrow.triangle.2.circlepath", "自动接力：已开放；运行中的 CLI 是否即时换号待实测")
                boundary("questionmark.circle", "跨账号服务端缓存：未知")
                boundary("terminal", "会话恢复：不自动重放指令")
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading).object()
            HStack(spacing: 8) {
                Button("导出诊断", systemImage: "square.and.arrow.up") { model.exportDiagnostics() }.buttonStyle(.lilt(.surface))
                    .help("导出不含 Token、账号标识、备注、凭据链接或命令输出。")
                if !model.demo { Button("看看演示") { model.startDemo() }.buttonStyle(.lilt(.ghost)) }
                Spacer()
                Text("无遥测 · 无云同步").font(Typo.caption).foregroundStyle(Tokens.muted)
            }
        }
    }
    private func fact(_ name: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(Typo.body).foregroundStyle(Tokens.muted)
                Spacer()
                Text(value).font(Typo.label).textSelection(.enabled)
            }
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            if !last { Rectangle().fill(Tokens.separator).frame(height: 1) }
        }
    }
    private func boundary(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.muted).frame(width: 18).accessibilityHidden(true)
            Text(text).font(Typo.body)
        }
    }
}
