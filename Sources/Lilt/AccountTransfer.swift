import Foundation
import LiltCore

/// The macOS side of moving accounts between machines: what goes into an archive, and where an import writes. The
/// rules and the transaction itself are `CredentialImport`'s, shared with the Linux daemon; the encryption is
/// `CredentialTransfer`'s. Lilt's secrets and its account file sit side by side under `Disk.root` on both platforms.
enum AccountVaultTransfer {
    static var secrets: URL { Disk.root.appendingPathComponent("secrets", isDirectory: true) }
    static var libraryFile: URL { Disk.file("accounts.json") }

    /// Every account's stored login and identity record, with the kind its login actually has.
    static func snapshot(of library: Library) throws -> [TransferItem] {
        try library.accounts.map { account in
            guard let credential = try AccountVault.read(account: account.id.uuidString) else {
                throw AppFailure("账号库有缺失的凭据，未导出。")
            }
            return TransferItem(localID: account.id, label: account.label,
                                kind: Credential(data: credential).refreshable ? .oauth : .setupToken,
                                credential: credential, identity: try AccountVault.read(account: Keychain.identityAccount(account.id)))
        }
    }

    /// Plans and commits an import onto `base`. Runs on the I/O queue.
    static func commit(_ items: [TransferItem], base: Library, failAt: String? = nil) throws -> CredentialImport.Result {
        let plan = try CredentialImport.plan(items, into: base, stored: { try AccountVault.read(account: $0.uuidString) },
                                             storedIdentity: { try AccountVault.read(account: Keychain.identityAccount($0)) })
        return try CredentialImport.commit(plan, base: base, secrets: secrets, libraryFile: libraryFile, failAt: failAt)
    }

    static func recover() throws {
        try CredentialImport.recover(secrets: secrets, libraryFile: libraryFile)
    }
}
