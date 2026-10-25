import Foundation
import LiltCore

/// The macOS import writes beside the existing secrets, never over them, and leaves the runtime login alone.
@MainActor
func transferStoreChecks() throws {
    let libraryFile = Disk.file("accounts.json")
    let originalLibrary = try? Data(contentsOf: libraryFile)
    let runtimeFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    let originalRuntime = try? Data(contentsOf: runtimeFile)
    let existingID = UUID(), oauthID = UUID(), tokenID = UUID(), failedID = UUID(), committedID = UUID()
    let allIDs = [existingID, oauthID, tokenID, failedID, committedID]
    defer {
        for id in allIDs {
            try? AccountVault.delete(account: id.uuidString)
            try? AccountVault.delete(account: Keychain.identityAccount(id))
        }
        if let originalLibrary { try? Disk.write(originalLibrary, to: libraryFile) }
        else { try? FileManager.default.removeItem(at: libraryFile) }
        if let originalRuntime { try? Disk.write(originalRuntime, to: runtimeFile) }
        else { try? FileManager.default.removeItem(at: runtimeFile) }
    }
    // Fixed bytes per name: JSON encoders do not promise one key order from one call to the next.
    func credential(_ name: String, refresh: Bool = true) -> Data {
        let refreshToken = refresh ? #","refreshToken":"fixture-refresh-\#(name)""# : ""
        return Data(#"{"claudeAiOauth":{"accessToken":"fixture-access-\#(name)","expiresAt":4102444800000,"scopes":["user:profile","user:inference"]\#(refreshToken)}}"#.utf8)
    }
    func identity(_ name: String) -> Data {
        Data(#"{"accountUuid":"fixture-stable-\#(name)","emailAddress":"fixture@example.invalid"}"#.utf8)
    }
    try AccountVault.write(credential("existing"), account: existingID.uuidString)
    try AccountVault.write(identity("existing"), account: Keychain.identityAccount(existingID))
    var base = Library()
    base.accounts = [Account(id: existingID, label: "Fixture existing", kind: .oauth)]
    base.activeID = existingID
    base.preferences.autoRelay = true
    try Disk.write(JSONEncoder().encode(base), to: libraryFile)
    try Disk.write(Data("fixture-runtime-state".utf8), to: runtimeFile)
    let oauth = TransferItem(localID: oauthID, label: "Fixture OAuth", kind: .oauth, credential: credential("oauth"), identity: identity("oauth"))
    let token = TransferItem(localID: tokenID, label: "Fixture Token", kind: .setupToken, credential: credential("token", refresh: false))
    let result = try AccountVaultTransfer.commit([oauth, token], base: base)
    precondition(result.added == 2 && result.library.accounts.count == 3)
    precondition(result.library.activeID == existingID && result.library.preferences.autoRelay == false)
    for id in [oauthID, tokenID] {
        let account = try require(result.library.accounts.first { $0.id == id })
        precondition(!account.enabled && account.usage == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: Disk.root.appendingPathComponent("secrets/\(id.uuidString)").path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o600)
    }
    let imported = try require(result.library.accounts.first { $0.id == tokenID })
    precondition(imported.usageCapability == .unavailable)
    let runtimeAfter = try Data(contentsOf: runtimeFile)
    precondition(runtimeAfter == Data("fixture-runtime-state".utf8))

    let repeated = try AccountVaultTransfer.commit([oauth, token], base: result.library)
    precondition(repeated.added == 0 && repeated.skipped == 2 && repeated.conflicts == 0)
    let conflict = TransferItem(localID: oauthID, label: "Conflict", kind: .oauth, credential: credential("different"), identity: identity("different"))
    let conflicted = try AccountVaultTransfer.commit([conflict], base: result.library)
    precondition(conflicted.added == 0 && conflicted.conflicts == 1)
    let kept = try AccountVault.read(account: oauthID.uuidString)
    precondition(kept == credential("oauth"), "a conflict replaced a stored login")
    let duplicateStable = TransferItem(localID: UUID(), label: "Duplicate", kind: .oauth, credential: credential("other"), identity: identity("oauth"))
    let deduplicated = try AccountVaultTransfer.commit([duplicateStable], base: result.library)
    precondition(deduplicated.added == 0 && deduplicated.skipped == 1)

    let failed = TransferItem(localID: failedID, label: "Failed", kind: .oauth, credential: credential("failed"))
    do {
        _ = try AccountVaultTransfer.commit([failed], base: result.library, failAt: "links")
        preconditionFailure("Expected injected import failure")
    } catch {}
    precondition(!AccountVault.hasFile(account: failedID.uuidString))
    let committed = TransferItem(localID: committedID, label: "Committed", kind: .oauth, credential: credential("committed"))
    _ = try AccountVaultTransfer.commit([committed], base: result.library, failAt: "afterCommit")
    try AccountVaultTransfer.recover()
    precondition(AccountVault.hasFile(account: committedID.uuidString))
    let secrets = Disk.root.appendingPathComponent("secrets")
    let journals = try FileManager.default.contentsOfDirectory(at: secrets, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("import") }
    precondition(journals.isEmpty)
    // What an export would carry: each account's stored login and identity, with the kind its login really has.
    let snapshot = try AccountVaultTransfer.snapshot(of: result.library)
    precondition(snapshot.count == 3 && snapshot.first { $0.localID == tokenID }?.kind == .setupToken && OAuthDocument.Identity(oauthAccount: snapshot.first { $0.localID == oauthID }?.identity).account == "fixture-stable-oauth")
    let elsewhere = try CredentialImport.plan(snapshot, into: Library(), stored: { _ in nil }, storedIdentity: { _ in nil })
    precondition(elsewhere.additions.count == 3 && elsewhere.additions.allSatisfy { !$0.enabled }, "a snapshot does not import elsewhere")
    print("PASS: account import on macOS — adds only, disabled, relay off, never replaces a stored login, failure and crash recovery, runtime untouched.")
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw AppFailure("Fixture missing") }
    return value
}
