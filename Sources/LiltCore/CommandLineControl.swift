import Foundation

/// What the `lilt` command in a terminal asks the running Lilt app: one JSON line each way over a socket in Lilt's own
/// directory. The app does the work, so a switch from a terminal goes through the same journal, renewal and relay rules
/// as a click. Nothing here carries a credential.
public struct ControlRequest: Codable, Equatable, Sendable {
    /// `list`, `use` (with `ids`) or `all`.
    public var action: String
    public var ids: [UUID]?
    public init(action: String, ids: [UUID]? = nil) { self.action = action; self.ids = ids }
}

/// One account as `lilt` lists it, in the relay order the app shows.
public struct ControlAccount: Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var active: Bool
    public var enabled: Bool
    /// Fixed to a project; the default login never takes it.
    public var project: Bool
    /// Relay may hand off to it: inside the pool `lilt` set, or there is none.
    public var inPool: Bool
    /// What the last reading left, however old it is; nil when unknown.
    public var fiveHour: Double?
    public var sevenDay: Double?
    public var noWeeklyLimit: Bool
    public var sampledAt: Date?
    public init(id: UUID, label: String, active: Bool, enabled: Bool, project: Bool, inPool: Bool,
                fiveHour: Double?, sevenDay: Double?, noWeeklyLimit: Bool, sampledAt: Date?) {
        self.id = id; self.label = label; self.active = active; self.enabled = enabled; self.project = project
        self.inPool = inPool; self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.noWeeklyLimit = noWeeklyLimit
        self.sampledAt = sampledAt
    }
}

public struct ControlReply: Codable, Equatable, Sendable {
    public var ok: Bool
    /// What the terminal prints, one sentence per line.
    public var lines: [String]
    public var accounts: [ControlAccount]?
    /// The pool in force, or nil when relay may use every account.
    public var pool: [UUID]?
    public var autoRelay: Bool?
    /// Why relay waits or cannot be switched on, or when it hands off.
    public var relayNote: String?
    public init(ok: Bool, lines: [String] = [], accounts: [ControlAccount]? = nil, pool: [UUID]? = nil,
                autoRelay: Bool? = nil, relayNote: String? = nil) {
        self.ok = ok; self.lines = lines; self.accounts = accounts; self.pool = pool; self.autoRelay = autoRelay
        self.relayNote = relayNote
    }
    public static func failure(_ text: String) -> ControlReply { ControlReply(ok: false, lines: [text]) }
}

/// The accounts relay may hand off to.
public enum RelayPool {
    /// The pool as relay applies it: the ids of accounts that still exist. Nil when none was set, or when none of it
    /// is left, so removing every account of a pool frees relay rather than locking it on nothing.
    public static func effective(_ pool: [UUID]?, accounts: [Account]) -> Set<UUID>? {
        guard let pool else { return nil }
        let existing = Set(accounts.map(\.id))
        let kept = Set(pool).intersection(existing)
        return kept.isEmpty ? nil : kept
    }
}

public enum AccountMatch: Equatable, Sendable { case one(Int), several([Int]), none }

/// Which account a word typed after `lilt` names, the way `ccl` finds a provider: ignoring case, an exact name first,
/// then a number in the order shown, then a name that starts with it, contains it, or has its letters in order
/// (`ent` → "Enterprise"). The exact name comes before the number, so an account called "003" is found by "003"
/// rather than taken for the third account.
public enum AccountQuery {
    /// `labels` in the order shown; the result is a position in it, from 0.
    public static func match(_ query: String, labels: [String]) -> AccountMatch {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return .none }
        let names = labels.map { $0.lowercased() }
        func pick(_ hits: [Int]) -> AccountMatch? {
            switch hits.count { case 0: nil; case 1: .one(hits[0]); default: .several(hits) }
        }
        if let exact = pick(names.indices.filter { names[$0] == wanted }) { return exact }
        if wanted.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(wanted), number >= 1, number <= labels.count {
            return .one(number - 1)
        }
        if let prefix = pick(names.indices.filter { names[$0].hasPrefix(wanted) }) { return prefix }
        if let inside = pick(names.indices.filter { names[$0].contains(wanted) }) { return inside }
        return pick(names.indices.filter { inOrder(wanted, names[$0]) }) ?? .none
    }
    private static func inOrder(_ letters: String, _ name: String) -> Bool {
        var rest = Substring(name)
        for letter in letters {
            guard let found = rest.firstIndex(of: letter) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}
