import Foundation
import LiltCore

/// How to start the official CLI on one project: its directory, its configuration and the single-line command.
struct ProjectLaunchPlan: Sendable {
    var projectID: UUID
    var rootPath: String
    var configDirectory: String
    var command: String
}

enum ProjectSupport {
    /// The directory the user picked, as one canonical path, and the name to show for it. It must exist, and the
    /// repository's own Claude settings must not put an API key or provider in place of a subscription login.
    static func validate(root: String) throws -> (root: String, name: String) {
        guard !root.isEmpty, root.hasPrefix("/"), !root.contains("\0"), !root.contains("\n"), !root.contains("\r") else {
            throw AppFailure("项目路径无效，请选择一个实际目录。")
        }
        let normalized = ProjectBinding.normalizedRoot(root)
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &directory), directory.boolValue else {
            throw AppFailure("项目目录不存在，或不是目录。")
        }
        if let problem = ProjectRules.repositoryProblem(root: normalized) { throw AppFailure(problem) }
        let name = URL(fileURLWithPath: normalized, isDirectory: true).lastPathComponent
        return (normalized, name.isEmpty ? "项目" : name)
    }

    /// The command enters the project, removes the variables that could put another login or provider in place of
    /// the project's, points the CLI at the project's configuration and keychain item, and replaces the shell with it.
    static func launchPlan(for project: ProjectBinding, runtime: RuntimeScope, executable: String?,
                           arguments: [String] = []) throws -> ProjectLaunchPlan {
        guard let executable else { throw AppFailure("未找到官方 Claude Code CLI；没有启动其他命令。") }
        return ProjectLaunchPlan(projectID: project.id, rootPath: project.rootPath, configDirectory: runtime.directory.path,
                                 command: runtime.launchCommand(executable: executable, arguments: arguments))
    }

    /// Terminal runs the command in a new window; nothing else is started, and an already running session is never
    /// touched or moved.
    static func openTerminal(_ plan: ProjectLaunchPlan) async throws {
        let escaped = plan.command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        try await IOQueue.run {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw AppFailure("无法打开 Terminal；请复制启动命令后在项目终端运行。") }
        }
    }
}
