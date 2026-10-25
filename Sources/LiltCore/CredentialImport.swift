import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One account as it travels between machines: Lilt's local id and note, the kind, the credential document and the
/// CLI's `oauthAccount` record. Nothing about quota, relay, the scope or the order goes along.
public struct TransferItem: Codable, Equatable, Sendable {
    public var localID: UUID
    public var label: String
    public var kind: AuthKind
    public var credential: Data
    public var identity: Data?

    public init(localID: UUID, label: String, kind: AuthKind, credential: Data, identity: Data? = nil) {
        self.localID = localID
        self.label = label
        self.kind = kind
        self.credential = credential
        self.identity = identity
    }
}

public struct ImportFailure: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Adding accounts from another machine. An import only ever adds: an account that is already here, by Lilt's id or
/// by the Claude account id its identity record names, is skipped, and one whose id is here with a different login
/// counts as a conflict and is left alone. An older archive therefore never replaces a newer refresh token. Notes,
/// emails and token digests are not identities and are never used to merge.
///
/// Added accounts arrive disabled, with quota and capabilities unknown, and the import turns automatic relay off: they
/// take part in nothing until the user has looked at them. No runtime scope is written, so the login Claude Code is
/// using and every running session stay as they are.
public enum CredentialImport {
    public struct Plan: Equatable, Sendable {
        public var additions: [Account]
        public var files: [String: Data]
        public var skipped: Int
        public var conflicts: Int
    }

    public struct Result: Sendable {
        public var library: Library
        public var added: Int
        public var skipped: Int
        public var conflicts: Int
    }

    /// Where an identity record is kept beside its credential.
    public static func identityName(_ id: UUID) -> String { id.uuidString + ".identity" }

    /// Checks the whole archive before anything is decided, then sorts each account into added, skipped or conflict.
    /// `stored` and `storedIdentity` read what this machine already keeps for an id.
    public static func plan(_ items: [TransferItem], into library: Library, stored: (UUID) throws -> Data?,
                            storedIdentity: (UUID) throws -> Data?, at now: Date = .now) throws -> Plan {
        var ids = Set<UUID>(), accounts = Set<String>()
        for item in items {
            guard ids.insert(item.localID).inserted else { throw ImportFailure("归档包含重复的本地记录，未导入。") }
            if let stable = OAuthDocument.Identity(oauthAccount: item.identity).account, !accounts.insert(stable).inserted {
                throw ImportFailure("归档包含同一账号的两份登录，未导入。")
            }
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 100 else { throw ImportFailure("归档包含无效备注，未导入。") }
            guard let access = OAuthDocument.accessToken(item.credential), !access.contains(where: \.isWhitespace) else {
                throw ImportFailure("归档包含无效凭据，未导入。")
            }
            let refreshable = OAuthDocument.refreshToken(item.credential) != nil
            guard item.kind == (refreshable ? .oauth : .setupToken) else { throw ImportFailure("归档的认证方式与凭据结构不一致，未导入。") }
            if !refreshable, let expiry = OAuthDocument.expiry(item.credential), expiry <= now {
                throw ImportFailure("归档中的长效 Token 已过期，未导入。")
            }
        }
        var existing = Set<String>()
        for account in library.accounts {
            if let stable = OAuthDocument.Identity(oauthAccount: try storedIdentity(account.id)).account { existing.insert(stable) }
        }
        let known = Set(library.accounts.map(\.id))
        var plan = Plan(additions: [], files: [:], skipped: 0, conflicts: 0)
        for item in items {
            if known.contains(item.localID) {
                if try stored(item.localID) == item.credential { plan.skipped += 1 } else { plan.conflicts += 1 }
                continue
            }
            if let stable = OAuthDocument.Identity(oauthAccount: item.identity).account, existing.contains(stable) {
                plan.skipped += 1; continue
            }
            var account = Account(id: item.localID, label: item.label.trimmingCharacters(in: .whitespacesAndNewlines), kind: item.kind)
            account.enabled = false
            account.expiresAt = OAuthDocument.expiry(item.credential)
            // A long-lived token cannot read subscription quota; saying so keeps it out of automatic relay for good.
            account.usageCapability = item.kind == .setupToken ? .unavailable : .unknown
            plan.additions.append(account)
            plan.files[item.localID.uuidString] = item.credential
            if let identity = item.identity { plan.files[identityName(item.localID)] = identity }
        }
        return plan
    }

    private struct Journal: Codable {
        var id: String
        var accounts: [UUID]
        var files: [String: String]
    }

    /// Writes the plan's secrets beside the existing ones, then the account library, in that order. The library write
    /// is the commit: before it, every file this import created is removed again; after it, they are the accounts'
    /// logins. A secret that already exists under a name stops the import without replacing it. A journal in
    /// `secrets` lets `recover` finish or undo an import a crash interrupted. `failAt` injects a failure for checks.
    public static func commit(_ plan: Plan, base: Library, secrets: URL, libraryFile: URL, failAt: String? = nil) throws -> Result {
        guard !plan.additions.isEmpty else { return Result(library: base, added: 0, skipped: plan.skipped, conflicts: plan.conflicts) }
        func checkpoint(_ point: String) throws {
            if failAt == point || failAt == "crash:" + point { throw ImportFailure("导入检查故障：\(point)") }
        }
        var updated = base
        updated.accounts.append(contentsOf: plan.additions)
        updated.preferences.autoRelay = false
        updated.preferences.autoRelayStopReason = nil
        try SecureFiles.directory(secrets)
        let transaction = UUID().uuidString
        let staging = secrets.appendingPathComponent(".import-\(transaction)", isDirectory: true)
        let journalFile = secrets.appendingPathComponent("import-\(transaction).journal")
        let journal = Journal(id: transaction, accounts: plan.additions.map(\.id), files: plan.files.mapValues(SHA256Digest.hex))
        var created: [String] = []
        do {
            try SecureFiles.write(JSONEncoder().encode(journal), to: journalFile)
            try checkpoint("journal")
            try SecureFiles.directory(staging)
            for (name, data) in plan.files { try SecureFiles.write(data, to: staging.appendingPathComponent(name)) }
            try checkpoint("staging")
            for name in plan.files.keys.sorted() {
                let source = staging.appendingPathComponent(name), destination = secrets.appendingPathComponent(name)
                try SecureFiles.rejectSymlinks(destination)
                guard link(source.path, destination.path) == 0 else { throw ImportFailure("导入时发现同名凭据，已停止；没有覆盖现有凭据。") }
                created.append(name)
            }
            try checkpoint("links")
            try SecureFiles.write(JSONEncoder().encode(updated), to: libraryFile)
        } catch {
            // "crash:<point>" stands for the process dying there: nothing is cleaned up, which `recover` must handle.
            if failAt?.hasPrefix("crash:") == true { throw error }
            // Nothing refers to the new files yet. Only files this import made, still holding what it wrote, go.
            for name in created.reversed() { removeIfUnchanged(secrets.appendingPathComponent(name), digest: journal.files[name]) }
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: journalFile)
            throw error
        }
        let result = Result(library: updated, added: plan.additions.count, skipped: plan.skipped, conflicts: plan.conflicts)
        if failAt == "afterCommit" { return result }
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: journalFile)
        return result
    }

    /// Finishes or undoes imports a crash interrupted, by what the library says: if it lists the journal's accounts the
    /// import committed and only its leftovers go; if it lists none, the files it created go too. A library that lists
    /// some of them was changed by something else, and everything is left for a person to look at.
    public static func recover(secrets: URL, libraryFile: URL) throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: secrets.path) else { return }
        for name in names where name.hasPrefix("import-") && name.hasSuffix(".journal") {
            let file = secrets.appendingPathComponent(name)
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))
            let library = (try? Data(contentsOf: libraryFile)).flatMap { try? JSONDecoder().decode(Library.self, from: $0) } ?? Library()
            let present = Set(library.accounts.map(\.id))
            let listed = journal.accounts.filter(present.contains).count
            if listed == journal.accounts.count {
                // Committed.
            } else if listed == 0 {
                for (secret, digest) in journal.files { removeIfUnchanged(secrets.appendingPathComponent(secret), digest: digest) }
            } else {
                throw ImportFailure("上次导入后账号库又有改动，已保留现场等待检查。")
            }
            try? FileManager.default.removeItem(at: secrets.appendingPathComponent(".import-\(journal.id)", isDirectory: true))
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func removeIfUnchanged(_ file: URL, digest: String?) {
        guard let digest, let data = try? Data(contentsOf: file), SHA256Digest.hex(data) == digest else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
