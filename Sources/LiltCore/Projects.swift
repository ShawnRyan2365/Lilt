import Foundation

/// Where a project's own Claude configuration stands. `preparing` is set before Lilt writes the project scope and
/// cleared only once the write has been read back; anything that cannot be accounted for becomes `conflict`.
public enum ProjectPhase: String, Codable, Sendable {
    case preparing, ready, conflict
}

/// One project directory with a fixed account. The project gets a Claude configuration directory of its own, derived
/// from `id`, so the account written there never touches the default login or another project. Nothing in here is
/// a secret: the account is Lilt's local id, and the path is the user's own directory.
public struct ProjectBinding: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rootPath: String
    public var accountID: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var phase: ProjectPhase
    /// The login was written to the project scope and no status line reading has shown a session on it yet.
    public var appliedPending: Bool
    public var issue: String?

    public init(id: UUID? = nil, name: String, rootPath: String, accountID: UUID, createdAt: Date = .now, updatedAt: Date = .now,
                phase: ProjectPhase = .preparing, appliedPending: Bool = false, issue: String? = nil) {
        let root = Self.normalizedRoot(rootPath)
        self.id = id ?? Self.stableID(forRoot: root)
        self.name = name
        self.rootPath = root
        self.accountID = accountID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.appliedPending = appliedPending
        self.issue = issue
    }

    /// The directory as one canonical path: `..` and symlinks resolved, no trailing slash. Two spellings of one
    /// directory must find the same binding, or one project could end up with two scopes.
    public static func normalizedRoot(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The same directory always gets the same id, on macOS and Linux alike, so unbinding and binding it again finds
    /// the configuration (and session history) it had. A moved directory is a different project.
    public static func stableID(forRoot rootPath: String) -> UUID {
        let hex = SHA256Digest.hex(Data("app.lilt.project.root.v1\0\(normalizedRoot(rootPath))".utf8))
        var bytes = stride(from: 0, to: 32, by: 2).map { index -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        // Version 5 layout (name-based), so the value reads as an ordinary UUID.
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The `scope` field status line events from this project's sessions carry.
    public var eventScope: String { LiveUsageEvent.projectScope(id) }
}

public struct ProjectCatalog: Codable, Equatable, Sendable {
    public var projects: [ProjectBinding]

    public init(projects: [ProjectBinding] = []) {
        self.projects = projects
    }

    /// Accounts fixed to a project. The default login's automatic relay never takes them, and switching the default
    /// login to one by hand is refused, so a project account is not spent by sessions it was not meant for.
    public var reservedAccountIDs: Set<UUID> { Set(projects.map(\.accountID)) }

    public func binding(id: UUID) -> ProjectBinding? {
        projects.first { $0.id == id }
    }

    /// The binding for exactly this directory. A subdirectory, a worktree elsewhere or a parent is not the project:
    /// each needs its own binding, so which scope a launch uses never depends on where the shell happens to be.
    public func binding(rootPath: String) -> ProjectBinding? {
        let root = ProjectBinding.normalizedRoot(rootPath)
        return projects.first { $0.rootPath == root }
    }

    public func projects(using account: UUID) -> [ProjectBinding] {
        projects.filter { $0.accountID == account }
    }

    /// Why this catalog cannot be trusted, or nil. A hand-edited or corrupt file that names one directory twice or
    /// carries an id that does not belong to its path would give one project two scopes.
    public var problem: String? {
        var ids = Set<UUID>(), roots = Set<String>()
        for project in projects {
            guard project.rootPath.hasPrefix("/"), project.rootPath == ProjectBinding.normalizedRoot(project.rootPath),
                  project.id == ProjectBinding.stableID(forRoot: project.rootPath) else { return "项目绑定的目录或标识无效。" }
            guard ids.insert(project.id).inserted, roots.insert(project.rootPath).inserted else { return "同一目录出现了两个项目绑定。" }
        }
        return nil
    }
}

/// The rules for binding a project, shared by the macOS app and the Linux daemon.
public enum ProjectRules {
    /// Why `account` cannot be fixed to the project at `root`, or nil. `replacing` is the project being rebound.
    /// An account already serving another project, or the default login, is only shared when the user says so:
    /// separate configurations each renew the same login on their own, and the quota is one quota either way.
    public static func bindingProblem(root: String, account: Account?, catalog: ProjectCatalog, defaultLoginAccount: UUID?,
                                      allowShared: Bool, replacing: UUID? = nil) -> String? {
        if replacing == nil, catalog.binding(rootPath: root) != nil { return "这个目录已经绑定；更换账号请用换绑。" }
        guard let account else { return "要绑定的账号不存在。" }
        guard account.enabled else { return "账号已停用，先启用再绑定。" }
        if account.refreshRejected == true { return "账号需要重新授权，之后再绑定。" }
        if !allowShared {
            if catalog.projects.contains(where: { $0.accountID == account.id && $0.id != replacing }) {
                return "这个账号已固定给另一个项目；确认共享额度和续期影响后再选择共享。"
            }
            if account.id == defaultLoginAccount { return "这个账号正在默认登录中使用；确认共享额度和续期影响后再选择共享。" }
        }
        return nil
    }

    /// Why a project cannot be launched right now, or nil. A launch never falls back to the default login.
    public static func launchProblem(_ project: ProjectBinding, account: Account?) -> String? {
        guard let account else { return "项目绑定的账号已不存在，请先换绑。" }
        guard account.enabled else { return "项目绑定的账号已停用；启用或换绑后再启动。" }
        if account.refreshRejected == true { return "项目账号需要重新授权。" }
        switch project.phase {
        case .ready: return nil
        case .preparing: return "项目接入未完成，请重新换绑或稍后再试。"
        case .conflict: return project.issue ?? "项目登录需要处理后才能启动。"
        }
    }

    /// Why the project's own `.claude` settings rule out a subscription login, or nil. A key, provider or base URL
    /// there would win over the project's account, and Lilt never edits files in the user's repository to remove it.
    public static func repositoryProblem(root: String) -> String? {
        for name in ["settings.json", "settings.local.json"] {
            let file = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(".claude/\(name)")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: file) else { return "项目 .claude/\(name) 无法安全读取（符号链接或过大），未接入。" }
            do {
                if try AuthenticationSettings.hasAPIOverride(data) {
                    return "项目 .claude/\(name) 设置了 API、供应商或登录方式；Lilt 不会修改它，请先改回官方订阅直连。"
                }
            } catch { return "项目 .claude/\(name) 不是有效的 JSON，未接入。" }
        }
        return nil
    }

    /// The environment a project launch removes before it sets its own configuration directory. A token or a
    /// provider set in the shell would otherwise win over the project's login, and the project would not be on its
    /// account at all.
    public static var clearedEnvironment: [String] {
        (AuthenticationSettings.credentialKeys + ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"]).sorted()
    }
}
