import Foundation
import AppKit
import LiltCore

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct UsageClient {
    func fetch(_ credential: Credential) async throws -> UsageSnapshot {
        try credential.validate()
        // Asking with a token that is known to have expired would only earn a 401 and look like a revoked login.
        if credential.accessExpired { throw UsageFailure.accessExpired }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credential.token!)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw UsageFailure.invalidResponse }
            switch response.statusCode {
            case 200: return try UsageParser.parse(data)
            case 401: throw UsageFailure.authentication
            case 403:
                // The usage endpoint needs the user:profile scope, which setup-token credentials do not carry.
                // Any other refusal is treated as a credential that no longer works. The body is inspected, never kept.
                let body = String(data: data.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
                let scopes = credential.oauth["scopes"] as? [String]
                let lacksProfile = scopes.map { !$0.contains("user:profile") } ?? false
                throw body.contains("scope") || body.contains("user:profile") || lacksProfile ? UsageFailure.permission : UsageFailure.authentication
            case 429:
                let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                let seconds = Double(header) ?? formatter.date(from: header).map { max(0, $0.timeIntervalSinceNow) } ?? 60
                throw UsageFailure.rateLimited(seconds)
            default: throw UsageFailure.invalidResponse
            }
        } catch let error as UsageFailure { throw error }
        catch { throw UsageFailure.network }
    }
}

/// Renews a full login's access token the way the official CLI does: its endpoint, its client id, its request body.
/// Lilt only does this for accounts that are not in the scope, so it never spends a refresh token a running CLI holds.
struct TokenRenewer {
    enum Failure: Error { case rejected, network, invalidResponse }
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client, the one these logins were issued to.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    func renew(_ credential: Credential) async throws -> Credential {
        guard let refresh = OAuthDocument.refreshToken(credential.data) else { throw Failure.rejected }
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientID]
        let scopes = OAuthDocument.scopes(credential.data)
        if !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        // Neither the request nor the answer is ever logged: both carry tokens.
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.network }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        switch http.statusCode {
        case 200:
            guard let renewed = OAuthDocument.renewed(credential.data, response: data, now: .now) else { throw Failure.invalidResponse }
            return Credential(data: renewed)
        case 400, 401, 403: throw Failure.rejected
        default: throw Failure.network
        }
    }
}

/// Whether ORCA is switching Claude accounts on this Mac too. Read-only and best effort: a flag in ORCA's own data
/// file, whose layout may change between ORCA versions. Nothing else from ORCA is read.
enum OrcaProbe {
    static func managesDefaultLogin() -> Bool {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // Only a copy of ORCA that is running switches anything. Each copy keeps its data in a folder named after the
        // app ("orca" for Orca.app, "Orca Relay" for Orca Relay.app), and the folder stays when the copy is no longer
        // used: an old build that last ran weeks ago, with its Claude switching still on, raised the warning for good.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() })
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: support.path))?
            .filter { $0.lowercased().hasPrefix("orca") && running.contains($0.lowercased()) } ?? []
        for app in apps {
            let profiles = support.appendingPathComponent(app).appendingPathComponent("profiles")
            for profile in (try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [] {
                let file = profiles.appendingPathComponent(profile).appendingPathComponent("orca-data.json")
                guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 20_000_000,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                if text.range(of: #""activeClaudeManagedAccountId"\s*:\s*"[^"]+""#, options: .regularExpression) != nil { return true }
            }
        }
        return false
    }
}

/// Asks the official profile endpoint, the one the CLI itself uses, whose login a credential is.
/// It is how Lilt tells a token the CLI renewed from a different account logged in inside the scope.
struct IdentityClient {
    /// The identity record, or nil when it cannot be told: no profile scope, no network, an unexpected answer.
    func fetch(_ credential: Credential) async -> Data? {
        guard let token = credential.token, !credential.accessExpired else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return OAuthDocument.identityRecord(fromProfile: data)
    }
}

@MainActor
final class CLILogin {
    private var process: Process?
    private var input: Pipe?
    private var cancelled = false
    static func cleanupStaleLogins() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Disk.root, includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey])
        for file in files where file.lastPathComponent.hasPrefix("login-") {
            guard UUID(uuidString: String(file.lastPathComponent.dropFirst(6))) != nil else { continue }
            let values = try file.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let created = values.creationDate, Date.now.timeIntervalSince(created) > 600 else { continue }
            try CLIKeychain.delete(service: Keychain.cliService(directory: file))
            try FileManager.default.removeItem(at: file)
        }
    }
    static var executable: URL? {
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return paths.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }
    static func version() async -> String {
        guard let executable else { return "未安装" }
        return await Task.detached {
            let p = Process(); let pipe = Pipe(); p.executableURL = executable; p.arguments = ["--version"]
            p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知版本"
                return result.count < 100 ? result : "未知版本"
            } catch { return "检测失败" }
        }.value
    }
    func submitCode(_ code: String) { try? input?.fileHandleForWriting.write(contentsOf: Data((code + "\n").utf8)) }
    func cancel() { cancelled = true; if process?.isRunning == true { process?.terminate() } }
    /// The login and, when the CLI recorded it, whose login it is (`oauthAccount` from the temporary config).
    func login() async throws -> (credential: Credential, identity: Data?) {
        guard process == nil, let executable = Self.executable else { throw AppFailure("未找到官方 Claude Code CLI，或授权已在进行。") }
        cancelled = false
        let temp = Disk.root.appendingPathComponent("login-\(UUID().uuidString)")
        try Disk.directory(temp)
        let service = Keychain.cliService(directory: temp)
        defer {
            try? CLIKeychain.delete(service: service)
            try? FileManager.default.removeItem(at: temp)
            process = nil; input = nil
        }
        let p = Process(); let stdin = Pipe(); let stdout = Pipe()
        p.executableURL = executable; p.arguments = ["auth", "login", "--claudeai"]
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") { env.removeValue(forKey: key) }
        env["CLAUDE_CONFIG_DIR"] = temp.path
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = temp.path
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        p.environment = env; p.currentDirectoryURL = temp
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stdout
        // Drain and discard CLI output: never log OAuth URLs, codes, or credentials.
        stdout.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        defer { stdout.fileHandleForReading.readabilityHandler = nil }
        process = p; input = stdin
        do { try p.run() } catch { throw AppFailure("无法启动官方登录命令。") }
        let deadline = Date.now.addingTimeInterval(180)
        while p.isRunning {
            if Date.now >= deadline { cancel() }
            if Date.now.timeIntervalSince(deadline) > 2 { kill(p.processIdentifier, SIGKILL) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !cancelled else { throw AppFailure("授权已取消或超时，临时凭据已清理。") }
        guard p.terminationStatus == 0 else { throw AppFailure("官方登录未完成，请重试；现有账号未修改。") }
        let file = temp.appendingPathComponent(".credentials.json")
        let data = try CLIKeychain.read(service: service) ?? (FileManager.default.fileExists(atPath: file.path) ? Data(contentsOf: file) : nil)
        guard let data else { throw AppFailure("登录完成，但此 CLI 的凭据存储尚不兼容。未导入账号。") }
        let credential = Credential(data: data); try credential.validate()
        return (credential, RuntimeScope.identity(in: temp))
    }
}
