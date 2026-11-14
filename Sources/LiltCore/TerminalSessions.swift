import Foundation

/// A Claude Code session `lilt` started in the user's own terminal, on a login of its own. It shares `~/.claude` and
/// `~/.claude.json` with every other session (settings, MCP servers, history); only where the CLI keeps its login
/// differs: `CLAUDE_SECURESTORAGE_CONFIG_DIR` points it at `sessions/<id>/secure`, whose keychain item and
/// `.credentials.json` signal belong to this session alone, so the default login and projects never see it.
/// Several accounts make a pool: when the one in use nears its threshold, Lilt writes the next one into the same place
/// and the running CLI moves to it, as the default login's relay does. Nothing in here is a secret.
public struct TerminalSession: Identifiable, Codable, Equatable, Sendable {
    /// `SessionRules.scopeID(pool:)`: the same accounts always find the same scope, so a second terminal asking for
    /// them joins the first instead of renewing the same logins somewhere else.
    public var id: UUID
    /// The accounts in the order typed: the first with room is used first, and relay goes down the list.
    public var pool: [UUID]
    /// The account whose login is in the scope. Nil only while the first one is being written.
    public var holding: UUID?
    /// The terminals running on it.
    public var leases: [SessionLease]
    public var createdAt: Date
    /// When `holding` last changed. Status line readings from before it are about the account before.
    public var switchedAt: Date
    /// The account relay just left and when, so two accounts near their threshold do not swap on every reading.
    public var departed: UUID?
    public var departedAt: Date?
    /// Why relay waits, for `lilt ls` and the app; nil when nothing holds it up.
    public var note: String?
    /// When a waiting relay looks again.
    public var retryAt: Date?
    /// When the last terminal was found gone. The login is read back and the scope cleared after that; a login that
    /// cannot be accounted for yet is tried again until `SessionRules.readBackGrace` has passed.
    public var endedAt: Date?

    public init(pool: [UUID], holding: UUID? = nil, leases: [SessionLease] = [], createdAt: Date = .now) {
        id = SessionRules.scopeID(pool: pool)
        self.pool = pool; self.holding = holding; self.leases = leases
        self.createdAt = createdAt; switchedAt = createdAt
    }

    public var relays: Bool { pool.count > 1 }
    /// The `scope` field status line events from this session carry.
    public var eventScope: String { LiveUsageEvent.sessionScope(id) }
}

/// One terminal on a session: the process `lilt` became when it started Claude Code. `lilt` replaces itself with the
/// CLI, so the pid is the CLI's, and the start time tells it apart from a later process given the same pid.
public struct SessionLease: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var started: Double
    public init(pid: Int32, started: Double) { self.pid = pid; self.started = started }
}

public struct SessionCatalog: Codable, Equatable, Sendable {
    public var sessions: [TerminalSession]
    public init(sessions: [TerminalSession] = []) { self.sessions = sessions }

    /// Every account of every session, held or waiting in a pool. The default login's relay and manual switching never
    /// take them, and Lilt never fixes them to a project, while the session lasts.
    public var reservedAccountIDs: Set<UUID> { Set(sessions.flatMap(\.pool)) }
    /// The accounts whose login is in a session's scope. Their CLI renews them; Lilt only reads the result back.
    public var heldAccountIDs: Set<UUID> { Set(sessions.compactMap(\.holding)) }

    public func session(id: UUID) -> TerminalSession? { sessions.first { $0.id == id } }
    public func session(containing account: UUID) -> TerminalSession? { sessions.first { $0.pool.contains(account) } }
    public func session(holding account: UUID) -> TerminalSession? { sessions.first { $0.holding == account } }

    /// Why this catalog cannot be trusted, or nil: an id that does not belong to its accounts, or an account in two
    /// sessions, would let two scopes renew one login.
    public var problem: String? {
        var ids = Set<UUID>(), accounts = Set<UUID>()
        for session in sessions {
            guard !session.pool.isEmpty, session.id == SessionRules.scopeID(pool: session.pool), ids.insert(session.id).inserted,
                  session.holding.map(session.pool.contains) ?? true else { return "独立会话记录无效。" }
            for account in session.pool where !accounts.insert(account).inserted { return "同一个账号出现在两个独立会话里。" }
        }
        return nil
    }
}

/// The rules for terminal sessions, kept apart from the app so they can be checked without a terminal.
public enum SessionRules {
    /// How long a session whose terminals are gone keeps its accounts while its login cannot be read back yet (a
    /// renewal whose owner the profile endpoint has not confirmed, say). After that the scope is cleared anyway.
    public static let readBackGrace: TimeInterval = 1800

    public static func scopeID(pool: [UUID]) -> UUID {
        let accounts = Set(pool).map(\.uuidString).sorted().joined(separator: ",")
        return SHA256Digest.nameUUID("app.lilt.session.pool.v1\0\(accounts)")
    }

    /// Why a session on `pool` cannot start, or nil. `defaultLogin` is the account the default login is on, when Lilt
    /// knows it: one login renewed in two places logs one of them out, so neither it nor a project's account is taken.
    public static func startProblem(pool: [UUID], accounts: [Account], sessions: SessionCatalog, projects: ProjectCatalog,
                                    defaultLogin: UUID?) -> String? {
        guard !pool.isEmpty else { return "没有指定账号。" }
        let id = scopeID(pool: pool)
        for accountID in pool {
            guard let account = accounts.first(where: { $0.id == accountID }) else { return "有账号已被删除；运行 lilt ls 重新查看。" }
            let name = "“\(account.label)”"
            if projects.reservedAccountIDs.contains(accountID) { return "\(name)已固定给项目，独立会话不能用它。" }
            if accountID == defaultLogin {
                return "\(name)正在本机默认登录里用；同一个登录在两处各自续期，会让其中一处掉登录。换一个账号，或先在 Lilt 里把默认登录换走。"
            }
            if account.refreshRejected == true { return "\(name)需要重新授权；先在 Lilt 里重新登录它。" }
            if let other = sessions.sessions.first(where: { $0.id != id && $0.pool.contains(accountID) }) {
                let names = other.pool.compactMap { member in accounts.first { $0.id == member }?.label }.joined(separator: "、")
                return "\(name)已在另一个独立会话里（\(names)）；同一个账号同时只给一个会话用。"
            }
        }
        return nil
    }

    /// The account a new session starts on: the first listed that its last reading does not show used up until a
    /// reset, an account without a reading counting as worth a try; the first listed when all are used up.
    public static func firstHolder(_ pool: [Account], threshold: Thresholds, at now: Date) -> Account? {
        pool.first { !($0.usage?.remainsExhausted(threshold: threshold, at: now) ?? false) } ?? pool.first
    }

    /// The pool's other accounts in the order relay considers them: down the list from the one in use, then round
    /// from the top.
    public static func relayOrder(_ pool: [UUID], after holding: UUID?) -> [UUID] {
        guard let holding, let index = pool.firstIndex(of: holding) else { return pool }
        return Array(pool[(index + 1)...]) + Array(pool[..<index])
    }

    /// `lilt 001 002 -c` → accounts `001 002`, then everything from the first option on for `claude`. Everything after
    /// `--` goes to `claude` as well, which is how a prompt or a subcommand is passed.
    public static func split(_ arguments: [String]) -> (selectors: [String], passthrough: [String]) {
        var selectors: [String] = []
        for (index, word) in arguments.enumerated() {
            if word == "--" { return (selectors, Array(arguments[(index + 1)...])) }
            if word.hasPrefix("-") { return (selectors, Array(arguments[index...])) }
            selectors.append(word)
        }
        return (selectors, [])
    }

    /// `claude` subcommands (2.1.x). Permission prompts are a session's, so these never get the bypass option.
    public static let subcommands: Set<String> = [
        "agents", "attach", "auth", "auto-mode", "config", "doctor", "gateway", "import", "install", "kill", "logs", "mcp",
        "migrate-installer", "plugin", "plugins", "purge", "respawn", "rm", "setup-token", "stop", "ultrareview", "update", "upgrade",
    ]

    /// The arguments `claude` is started with, and whether Lilt added `--dangerously-skip-permissions`. Like `ccl`, it is
    /// added unless turned off (`lilt bypass off`), and never when the arguments already choose a permission mode or
    /// start a subcommand.
    public static func claudeArguments(_ passthrough: [String], bypass: Bool) -> (arguments: [String], bypassed: Bool) {
        let chosen = passthrough.contains { $0 == "--dangerously-skip-permissions" || $0.hasPrefix("--permission-mode") }
        let subcommand = passthrough.first.map(subcommands.contains) ?? false
        guard bypass, !chosen, !subcommand else { return (passthrough, false) }
        return (passthrough + ["--dangerously-skip-permissions"], true)
    }
}
