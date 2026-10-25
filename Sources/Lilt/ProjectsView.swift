import SwiftUI
import LiltCore

private struct ProjectEditor: Identifiable {
    let id = UUID()
    var project: ProjectBinding?
    var rootPath: String
    var accountID: UUID?
}

struct ProjectsView: View {
    @Bindable var model: AppModel
    @State private var editor: ProjectEditor?
    @State private var unbinding: ProjectBinding?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("项目固定账号").font(Typo.title)
                    Text("每个项目使用独立 Claude 配置；固定账号，不自动换号。")
                        .font(Typo.caption).foregroundStyle(Tokens.muted)
                }
                Spacer()
                Button {
                    guard let account = model.accounts.first(where: \.enabled) else {
                        model.message = "先添加并启用一个账号，再绑定项目。"
                        return
                    }
                    editor = ProjectEditor(project: nil, rootPath: "", accountID: account.id)
                } label: { Label("绑定项目", systemImage: "plus") }
                    .buttonStyle(.lilt(.primary)).disabled(model.demo || model.accounts.isEmpty || !model.projectsAvailable)
            }
            if model.demo {
                InlineNote(tone: .neutral, symbol: "info.circle", text: "演示模式不展示、也不修改项目绑定。退出演示后回到真实账号。")
            } else if model.projectCatalog.projects.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("一个项目，一个账号", systemImage: "folder.badge.person.crop").font(Typo.heading)
                    Text("绑定后用 Lilt 的项目入口启动 Claude Code。不同项目互不切号，项目专用账号也不会进入默认登录的自动接力。")
                        .font(Typo.body).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                    Text("已经运行的 Orca 或终端进程需要一次性安全退出，再从项目入口接入；Lilt 不会强退或迁移它们。")
                        .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                    Text("项目使用独立的 Claude 配置目录：用户级 settings、MCP、记忆和插件不会自动带入，仓库里的 .claude 配置照常生效。")
                        .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading).object()
            } else {
                ForEach(model.projectCatalog.projects) { project in
                    row(project)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Tokens.muted)
                Text("同一项目的多个 CLI 会一起换绑；不同项目各用独立配置，互不影响。同一账号分给多个项目时，订阅额度仍然共享，各处会分别续期同一登录。已经发出的请求仍属于原账号。")
                    .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
        .sheet(item: $editor) { request in
            ProjectEditorView(model: model, request: request) { root, accountID, allowShared in
                if let project = request.project {
                    return await model.rebindProject(project.id, accountID: accountID, allowShared: allowShared)
                }
                return await model.bindProject(root: root, accountID: accountID, allowShared: allowShared)
            }
        }
        .confirmationDialog("解绑“\(unbinding?.name ?? "")”？", isPresented: Binding(get: { unbinding != nil }, set: { if !$0 { unbinding = nil } })) {
            Button("解绑并保留项目登录", role: .destructive) {
                if let unbinding { model.unbindProject(unbinding.id) }
                unbinding = nil
            }
            Button("取消", role: .cancel) { unbinding = nil }
        } message: { Text("只停止 Lilt 管理，不删除项目配置、会话历史或当前登录；该账号会重新可参与默认自动接力。") }
    }

    private func row(_ project: ProjectBinding) -> some View {
        let account = model.accounts.first { $0.id == project.accountID }
        let summary = QuotaSummary(snapshot: account?.usage, thresholds: model.thresholds, now: model.clock)
        let busy = model.projectBusy.contains(project.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder").frame(width: 30, height: 30).background(Tokens.fill, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(project.name).font(Typo.heading).lineLimit(1)
                        Pill(text: phase(project.phase), style: project.phase == .ready ? .soft(.success) : .soft(.warning))
                        if project.phase == .ready, project.appliedPending { Pill(text: "等待会话验证").help("登录已写入项目配置，还没有会话报告这个账号的额度") }
                        if model.projectCatalog.projects(using: project.accountID).count > 1 { Pill(text: "额度共享", style: .soft(.warning)) }
                    }
                    Text(project.rootPath).font(Typo.caption).foregroundStyle(Tokens.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .center, spacing: 12) {
                if let account {
                    Sprite(slot: model.spriteSlot(account.id), size: 28, mood: model.mood(of: account))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label).font(Typo.label).lineLimit(1)
                        Text(account.kind == .setupToken ? "长效 Token · 看不到订阅额度" : "固定账号 · 不参与默认接力")
                            .font(Typo.caption).foregroundStyle(Tokens.muted)
                    }
                } else {
                    Label("绑定账号已不存在", systemImage: "exclamationmark.triangle").foregroundStyle(Tone.warning.text)
                }
                Spacer()
                if let usage = account?.usage { FreshnessText(date: usage.sampledAt).font(Typo.caption).foregroundStyle(Tokens.muted) }
            }
            if account?.usage != nil {
                HStack(spacing: 20) {
                    ForEach(summary.windows, id: \.kind) { window in
                        QuotaCell(remaining: window.remaining, caption: window.caption,
                                  threshold: window.kind.threshold(in: model.thresholds), series: window.kind.series)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(window.spoken)
                    }
                }
            }
            if let usage = account?.usage, usage.remainsExhausted(threshold: model.thresholds, at: model.clock) {
                InlineNote(text: "已到阈值。项目固定账号不会自动换号；需要时手动更换绑定。")
            }
            if !FileManager.default.fileExists(atPath: project.rootPath) {
                InlineNote(text: "项目目录已不存在。目录移动后需要解绑，再在新位置重新绑定。")
            }
            if let issue = project.issue { InlineNote(text: issue) }
            HStack(spacing: 8) {
                Button("启动项目") { Task { await model.launchProject(project.id) } }
                    .buttonStyle(.lilt(.primary, size: .small)).disabled(busy || account == nil)
                Button("复制启动命令") { Task { await model.copyProjectLaunchCommand(project.id) } }
                    .buttonStyle(.lilt(.secondary, size: .small)).disabled(busy || account == nil)
                Spacer()
                Menu {
                    if let account { Button("刷新账号额度") { Task { await model.refresh(account.id, manually: true) } } }
                    Button("更换绑定…") {
                        editor = ProjectEditor(project: project, rootPath: project.rootPath, accountID: project.accountID)
                    }
                    Button("解绑…", role: .destructive) { unbinding = project }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(18).object()
    }

    private func phase(_ phase: ProjectPhase) -> String {
        switch phase { case .preparing: "未完成"; case .ready: "已应用"; case .conflict: "需处理" }
    }
}

private struct ProjectEditorView: View {
    @Bindable var model: AppModel
    let request: ProjectEditor
    let save: (String, UUID, Bool) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var root: String
    @State private var accountID: UUID?
    @State private var allowShared = false
    @State private var saving = false

    init(model: AppModel, request: ProjectEditor, save: @escaping (String, UUID, Bool) async -> Bool) {
        _model = Bindable(model)
        self.request = request
        self.save = save
        _root = State(initialValue: request.rootPath)
        _accountID = State(initialValue: request.accountID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.project == nil ? "绑定项目" : "更换固定账号").font(.system(size: 20, weight: .semibold))
            if request.project == nil {
                LabeledContent("项目目录") {
                    HStack {
                        Text(root.isEmpty ? "尚未选择" : root).lineLimit(1).truncationMode(.middle)
                        Button("选择…", action: chooseDirectory)
                    }
                }
            } else {
                LabeledContent("项目", value: request.project?.name ?? "")
            }
            Picker("固定账号", selection: $accountID) {
                ForEach(model.accounts.filter(\.enabled)) { account in
                    Text(account.label).tag(Optional(account.id))
                }
            }
            if let accountID, sharesAccount(accountID) {
                Toggle("确认共享这个账号", isOn: $allowShared)
                Text("这个账号已用于另一个项目或默认登录。共享后订阅额度仍是同一份；各处会分别续期同一登录，若服务端轮换刷新令牌，其中一处可能需要重新登录。")
                    .font(Typo.caption).foregroundStyle(Tone.warning.text).fixedSize(horizontal: false, vertical: true)
            }
            Text("只影响通过 Lilt 项目入口启动的 CLI。绑定或换绑不会强退现有进程，也不会修改 ORCA 的账号库。")
                .font(Typo.caption).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.lilt(.ghost)).keyboardShortcut(.cancelAction)
                Button(request.project == nil ? "绑定" : "换绑") {
                    guard let accountID else { return }
                    saving = true
                    Task {
                        let saved = await save(root, accountID, allowShared)
                        saving = false
                        if saved { dismiss() }
                    }
                }
                .buttonStyle(.lilt(.primary)).keyboardShortcut(.defaultAction)
                .disabled(saving || accountID == nil || (request.project == nil && root.isEmpty))
            }
        }
        .padding(24).frame(width: 480).tint(Tokens.accentTint)
        .interactiveDismissDisabled(saving)
    }

    private func sharesAccount(_ id: UUID) -> Bool {
        model.projectCatalog.projects.contains { $0.accountID == id && $0.id != request.project?.id }
            || (model.managesDefaultLogin && model.library.activeID == id)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择项目"
        if panel.runModal() == .OK, let url = panel.url { root = url.path }
    }
}
