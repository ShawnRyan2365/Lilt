import SwiftUI
import LiltTransfer

struct CredentialTransferRequest: Identifiable {
    enum Mode { case export, `import` }
    let id = UUID()
    let mode: Mode
    let url: URL
}

enum CredentialTransferPanels {
    @MainActor static func exportURL() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Lilt-Accounts.lilt-credential-export"
        panel.prompt = "加密导出"
        panel.message = "文件包含可登录凭据，将使用你输入的口令加密。"
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor static func importURL() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "只新增账号，不覆盖现有凭据，也不改变当前 Claude 登录。"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct CredentialTransferView: View {
    let model: AppModel
    let request: CredentialTransferRequest
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var failure: String?
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(request.mode == .export ? "加密导出账号库" : "导入账号库", systemImage: "lock.shield")
                .font(.system(size: 20, weight: .semibold))
            Text(request.mode == .export
                 ? "包含完整登录凭据。持有导出文件和口令的人可以使用这些账号；这不是脱敏诊断，也不是云同步。两台机器各自续期同一登录时，先续期的一方可能让另一方的副本失效。"
                 : "只新增不覆盖。导入账号默认停用，自动接力关闭，当前钥匙串、Claude 登录和会话保持不变。")
                .font(Typo.body).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
            if let result {
                InlineNote(text: result)
            } else {
                SecureField("归档口令", text: $passphrase).textFieldStyle(.roundedBorder).disabled(working)
                if request.mode == .export {
                    SecureField("再次输入口令", text: $confirmation).textFieldStyle(.roundedBorder).disabled(working)
                    Text("口令至少 \(CredentialTransfer.minimumPassphraseCharacters) 个字符。Lilt 不保存口令，也无法替你找回；导出不会覆盖已有文件。")
                        .font(Typo.caption).foregroundStyle(Tokens.muted)
                }
                if let failure { InlineNote(text: failure) }
            }
            HStack {
                Spacer()
                Button(result == nil ? "取消" : "完成") {
                    passphrase = ""; confirmation = ""; dismiss()
                }
                .buttonStyle(.lilt(.ghost)).keyboardShortcut(.cancelAction).disabled(working)
                if result == nil {
                    Button(request.mode == .export ? "加密导出" : "导入") { Task { await perform() } }
                        .buttonStyle(.lilt(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(working || !valid)
                }
            }
        }
        .padding(24).frame(width: 470).tint(Tokens.accentTint)
        .interactiveDismissDisabled(working)
        .onDisappear { passphrase = ""; confirmation = "" }
    }

    private var valid: Bool {
        if request.mode == .import { return !passphrase.isEmpty }
        return CredentialTransfer.passphraseProblem(passphrase, confirmation: confirmation) == nil
    }

    private func perform() async {
        working = true; failure = nil
        do {
            if request.mode == .export {
                result = try await model.exportCredentials(to: request.url, passphrase: passphrase)
            } else {
                result = try await model.importCredentials(from: request.url, passphrase: passphrase)
            }
        } catch {
            failure = (error as? AppFailure)?.message ?? error.localizedDescription
        }
        passphrase = ""; confirmation = ""; working = false
    }
}
