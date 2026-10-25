import Foundation
import LiltCore

/// What `lilt run --project` needs from the daemon to start the official CLI on a project's own configuration. The
/// CLI finds the `claude` executable on its own PATH; the daemon's environment (a systemd unit) may not have it.
public struct ProjectLaunchPlan: Codable, Sendable, Equatable {
    public var projectID: UUID
    public var rootPath: String
    public var configDirectory: String
    public var unsetEnvironment: [String]

    public init(projectID: UUID, rootPath: String, configDirectory: String, unsetEnvironment: [String] = ProjectRules.clearedEnvironment) {
        self.projectID = projectID
        self.rootPath = rootPath
        self.configDirectory = configDirectory
        self.unsetEnvironment = unsetEnvironment
    }
}

/// `projects.json` beside the account library. It holds directories and Lilt's local account ids, never a secret.
public final class ProjectCatalogStore: @unchecked Sendable {
    public let store: BackendStore
    public init(store: BackendStore) { self.store = store }

    public static func id(forRoot rootPath: String) -> UUID { ProjectBinding.stableID(forRoot: rootPath) }

    public static func existingRoot(_ path: String) throws -> String {
        let root = ProjectBinding.normalizedRoot(path)
        var directory: ObjCBool = false
        guard root.hasPrefix("/"), !root.contains("\0"), FileManager.default.fileExists(atPath: root, isDirectory: &directory), directory.boolValue else {
            throw BackendFailure("项目目录不存在或不是目录：\(root)")
        }
        return root
    }

    /// A file that names one directory twice or carries a foreign id stops project launches and the default relay
    /// alike: it could otherwise hand one project's account to another.
    public func load() throws -> ProjectCatalog {
        try store.prepare()
        guard let data = try read(paths.projectsCatalog) else { return ProjectCatalog() }
        let catalog = try JSONDecoder().decode(ProjectCatalog.self, from: data)
        if let problem = catalog.problem { throw BackendFailure("projects.json：\(problem)已停止项目启动和默认接力。") }
        return catalog
    }

    public func save(_ catalog: ProjectCatalog) throws {
        try store.prepare()
        if let problem = catalog.problem { throw BackendFailure("项目绑定无效，未保存：\(problem)") }
        try SecureFiles.write(try JSONEncoder().encode(catalog), to: paths.projectsCatalog)
    }

    public func runtime(for project: ProjectBinding) -> RuntimeScopePaths {
        paths.projectRuntime(project.id)
    }

    private var paths: BackendPaths { store.paths }
    private func read(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw BackendFailure("projects.json 是符号链接，已拒绝读取。")
        }
        return try Data(contentsOf: file)
    }
}
