import Foundation
import LiltCore
import LiltTransfer

// MARK: - Moving accounts to another machine

extension AppModel {
    /// Writes the whole account library to `url`, encrypted with `passphrase`. Every scope is checked first and whatever
    /// a CLI renewed is taken in when it provably is the same login; a scope that cannot be accounted for stops the
    /// export, since the archive would carry a login that may already be spent. Never replaces an existing file.
    func exportCredentials(to url: URL, passphrase: String) async throws -> String {
        guard !demo, storageAvailable, !busy, !loggingIn, projectBusy.isEmpty else { throw AppFailure("正在切换账号、授权或处理项目，完成后再导出。") }
        if let problem = CredentialTransfer.passphraseProblem(passphrase) { throw AppFailure(problem) }
        guard !library.accounts.isEmpty else { throw AppFailure("账号库是空的，没有可导出的账号。") }
        if library.preferences.scopeEnabled {
            guard await confirmScope() else {
                throw AppFailure("默认登录的归属尚未确认（外部修改、未完成的切换或暂时读不到），未导出。")
            }
        }
        for project in projectCatalog.projects {
            guard project.phase == .ready else { throw AppFailure("项目“\(project.name)”的登录尚未确认，未导出。") }
            do { try await syncProject(project, target: nil) }
            catch { throw AppFailure("项目“\(project.name)”的登录尚未确认，未导出：\(Self.projectReason(error))") }
        }
        busy = true
        defer { busy = false }
        let snapshot = library
        let items = try await IOQueue.run { try AccountVaultTransfer.snapshot(of: snapshot) }
        let archive = try await Task.detached(priority: .userInitiated) { try CredentialTransfer.export(items, passphrase: passphrase) }.value
        do { try await IOQueue.run { try SecureFiles.create(archive, at: url) } }
        catch SecureFileError.exists { throw AppFailure("这个文件已经存在；导出不会覆盖任何文件，请换一个新文件名。") }
        catch { throw AppFailure("导出文件无法写入，没有留下部分文件。") }
        SwitchLog.record("exported")
        return "已加密导出 \(items.count) 个账号（文件权限 0600）。这是一次性迁移，不会同步之后的变化；两台机器各自续期同一登录时，先续期的一方可能让另一方的副本失效。"
    }

    /// Adds the accounts of an archive (see `CredentialImport`): new ones only, disabled, with automatic relay turned
    /// off. The default login, the projects and every running session stay as they are.
    func importCredentials(from url: URL, passphrase: String) async throws -> String {
        guard !demo, storageAvailable, !busy, !loggingIn, projectBusy.isEmpty else { throw AppFailure("正在切换账号、授权或处理项目，完成后再导入。") }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= CredentialTransfer.maximumArchiveBytes, let data = try? Data(contentsOf: url) else {
            throw AppFailure("归档不存在、为空或超过大小上限。")
        }
        let items: [TransferItem]
        do { items = try await Task.detached(priority: .userInitiated) { try CredentialTransfer.importArchive(data, passphrase: passphrase) }.value }
        catch { throw AppFailure(CredentialTransfer.Failure.invalidPassphraseOrArchive.errorDescription ?? "口令错误，或归档已损坏。") }
        busy = true
        defer { busy = false }
        // What is waiting to be saved goes first, so the import starts from the library as it is.
        flushSaves()
        let base = library
        let result: CredentialImport.Result
        do { result = try await IOQueue.run { try AccountVaultTransfer.commit(items, base: base) } }
        catch let failure as ImportFailure { throw AppFailure(failure.message) }
        if result.added > 0 {
            let known = Set(library.accounts.map(\.id))
            library.accounts.append(contentsOf: result.library.accounts.filter { !known.contains($0.id) })
            save()
            setAutoRelay(false)
            SwitchLog.record("imported")
        }
        return "新增 \(result.added)，跳过 \(result.skipped)，冲突 \(result.conflicts)。"
            + (result.added > 0 ? "新账号默认停用，自动接力已关闭；默认登录、项目和正在运行的会话没有改动。确认后再启用。" : "没有改动任何账号。")
    }
}
