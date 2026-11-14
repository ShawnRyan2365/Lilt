import Foundation

/// What the `lilt` command in a terminal asks the running Lilt app: one JSON line each way over a socket in Lilt's own
/// directory. The app writes the session's login, so a session goes through the same journal, renewal and relay rules
/// as the default login. Nothing here carries a credential: the reply names a directory, never what is in it.
public struct ControlRequest: Codable, Equatable, Sendable {
    /// `list`, `session` (with `ids`) or `bypass` (with `bypass` to change it, without to ask).
    public var action: String
    public var ids: [UUID]?
    public var bypass: Bool?
    public init(action: String, ids: [UUID]? = nil, bypass: Bool? = nil) { self.action = action; self.ids = ids; self.bypass = bypass }
}

/// One account as `lilt` lists it, in the relay order the app shows.
public struct ControlAccount: Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    /// The account the default login is on.
    public var active: Bool
    public var enabled: Bool
    /// Fixed to a project; sessions never take it.
    public var project: Bool
    /// In a terminal session's scope right now.
    public var sessionHeld: Bool
    /// Waiting in a terminal session's pool.
    public var sessionSpare: Bool
    /// What the last reading left, however old it is; nil when unknown.
    public var fiveHour: Double?
    public var sevenDay: Double?
    public var noWeeklyLimit: Bool
    public var sampledAt: Date?
    public init(id: UUID, label: String, active: Bool, enabled: Bool, project: Bool, sessionHeld: Bool = false, sessionSpare: Bool = false,
                fiveHour: Double?, sevenDay: Double?, noWeeklyLimit: Bool, sampledAt: Date?) {
        self.id = id; self.label = label; self.active = active; self.enabled = enabled; self.project = project
        self.sessionHeld = sessionHeld; self.sessionSpare = sessionSpare
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.noWeeklyLimit = noWeeklyLimit; self.sampledAt = sampledAt
    }
}

/// A running terminal session as `lilt ls` lists it.
public struct ControlSessionSummary: Codable, Equatable, Sendable {
    public var pool: [String]
    public var holding: String?
    public var terminals: Int
    public var note: String?
    public init(pool: [String], holding: String?, terminals: Int, note: String?) {
        self.pool = pool; self.holding = holding; self.terminals = terminals; self.note = note
    }
}

/// What a terminal needs to start Claude Code on a session: where the CLI keeps the session's login, which account is
/// in it, and whether to skip permission prompts.
public struct ControlLaunch: Codable, Equatable, Sendable {
    public var secureDirectory: String
    public var account: String
    public var pool: [String]
    /// Another terminal already runs on these accounts; this one joins it.
    public var joined: Bool
    public var bypass: Bool
    public init(secureDirectory: String, account: String, pool: [String], joined: Bool, bypass: Bool) {
        self.secureDirectory = secureDirectory; self.account = account; self.pool = pool; self.joined = joined; self.bypass = bypass
    }
}

public struct ControlReply: Codable, Equatable, Sendable {
    public var ok: Bool
    /// What the terminal prints, one sentence per line.
    public var lines: [String]
    public var accounts: [ControlAccount]?
    public var sessions: [ControlSessionSummary]?
    public var launch: ControlLaunch?
    /// Whether sessions skip permission prompts (`lilt bypass`).
    public var bypass: Bool?
    public init(ok: Bool, lines: [String] = [], accounts: [ControlAccount]? = nil, sessions: [ControlSessionSummary]? = nil,
                launch: ControlLaunch? = nil, bypass: Bool? = nil) {
        self.ok = ok; self.lines = lines; self.accounts = accounts; self.sessions = sessions; self.launch = launch; self.bypass = bypass
    }
    public static func failure(_ text: String) -> ControlReply { ControlReply(ok: false, lines: [text]) }
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
