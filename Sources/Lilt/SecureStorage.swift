import Foundation
import Security
import CryptoKit
import LiltCore

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
struct Credential {
    var data: Data
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
    var oauth: [String: Any] { object["claudeAiOauth"] as? [String: Any] ?? [:] }
    var token: String? { oauth["accessToken"] as? String }
    var expiresAt: Date? { (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
    /// A full login carries a refresh token; the official CLI renews the access token from it on its next request.
    var refreshable: Bool { !((oauth["refreshToken"] as? String) ?? "").isEmpty }
    var accessExpired: Bool { expires(within: 0) }
    func expires(within seconds: TimeInterval) -> Bool { expiresAt.map { $0 <= Date.now.addingTimeInterval(seconds) } ?? false }
    func validate() throws {
        guard let token, !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw AppFailure("凭据格式无效，请重新授权或替换 Token。") }
        // An expired access token only ends a credential that has nothing to renew it with.
        if accessExpired, !refreshable { throw AppFailure("凭据已过期，请重新授权。") }
    }
    static func manual(_ token: String) throws -> Credential {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("sk-ant-oat"), token.count > 24, !token.contains(where: { $0.isWhitespace }) else {
            throw AppFailure("请输入 Claude setup-token 生成的 OAuth Token；不接受 API Key。")
        }
        return Credential(data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token, "scopes": ["user:inference"]]]))
    }
}
struct Keychain {
    static let service = "app.lilt.accounts"
    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read(service: String = service, account: String) throws -> Data? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw AppFailure("钥匙串读取失败（\(status)）；请检查系统授权。") }
        return data
    }
    static func write(_ data: Data, service: String = service, account: String) throws {
        let q = query(service: service, account: account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw AppFailure("无法保存到钥匙串；未保存此凭据。") }
        } else if status != errSecSuccess { throw AppFailure("无法更新钥匙串（\(status)）。") }
    }
    static func delete(service: String = service, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure("无法删除本地钥匙串凭据。") }
    }
    /// Where an account's `oauthAccount` record is kept: beside its credential, never in the plain account file.
    static func identityAccount(_ id: UUID) -> String { id.uuidString + ".identity" }
    static func cliService(directory: URL) -> String {
        let path = directory.path.precomposedStringWithCanonicalMapping
        return "Claude Code-credentials-" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
    }
}
/// The keychain items the official CLI reads, reached the way the CLI and ORCA reach them: through /usr/bin/security.
/// Items made by that tool trust it, so going through it neither prompts for access nor locks the CLI out of an item
/// Lilt wrote. Secrets travel only on stdin and stdout, never in arguments, so they never show in a process list.
enum CLIKeychain {
    private static let tool = URL(fileURLWithPath: "/usr/bin/security")
    /// The keychain account the CLI files its login under: the macOS user name.
    static func account() throws -> String {
        let name = NSUserName()
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw AppFailure("这个 macOS 用户名不能用作钥匙串条目名。")
        }
        return name
    }
    @discardableResult
    private static func run(_ arguments: [String], input: String? = nil) throws -> (status: Int32, output: Data) {
        let process = Process(); let output = Pipe(); let stdin = Pipe()
        process.executableURL = tool; process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = stdin
        do { try process.run() } catch { throw AppFailure("无法访问钥匙串。") }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        // A keychain waiting for the user to allow access would otherwise hold Lilt up indefinitely.
        let deadline = Date.now.addingTimeInterval(5)
        while process.isRunning && Date.now < deadline { usleep(10_000) }
        if process.isRunning { process.terminate(); throw AppFailure("钥匙串没有响应，可能在等你允许访问。") }
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
    }
    static func read(service: String) throws -> Data? {
        let result = try run(["find-generic-password", "-s", service, "-a", try account(), "-w"])
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw AppFailure("读取 Claude Code 登录失败（钥匙串返回 \(result.status)）。") }
        var data = result.output
        if data.last == 0x0A { data.removeLast() }
        return data
    }
    static func write(_ data: Data, service: String) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(try account())\" -s \"\(service)\" -X \(hex)\n"
        // The tool reads commands one line at a time from a fixed buffer.
        guard command.utf8.count < 3800 else { throw AppFailure("凭据太长，无法写入钥匙串。") }
        let result = try run(["-i"], input: command)
        guard result.status == 0 else { throw AppFailure("写入 Claude Code 登录失败（钥匙串返回 \(result.status)）。") }
    }
    static func delete(service: String) throws {
        let result = try run(["delete-generic-password", "-s", service, "-a", try account()])
        guard result.status == 0 || result.status == 44 else { throw AppFailure("无法删除钥匙串里的临时登录。") }
    }
}
struct Disk {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Lilt")
    static func directory(_ url: URL) throws { try SecureFiles.directory(url) }
    static func write(_ data: Data, to url: URL) throws { try SecureFiles.write(data, to: url) }
    static func load() throws -> Library {
        try directory(root)
        let path = root.appendingPathComponent("accounts.json")
        if !FileManager.default.fileExists(atPath: path.path) { return Library() }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: path))
    }
    static func save(_ library: Library) throws { try write(JSONEncoder().encode(library), to: root.appendingPathComponent("accounts.json")) }
}

/// The place the official CLI looks for its login, written to as one transaction.
/// `system` is Claude Code's default login (keychain item `Claude Code-credentials`, `~/.claude`, `~/.claude.json`),
/// the same surfaces ORCA writes. `dedicated` is a directory of Lilt's own that only the launch command points at.
final class RuntimeScope {
    let target: ScopeTarget
    let directory: URL
    init(target: ScopeTarget) {
        self.target = target
        directory = target == .system ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
                                       : Disk.root.appendingPathComponent("scope")
    }
    private var file: URL { directory.appendingPathComponent(".credentials.json") }
    private var journal: URL { Disk.root.appendingPathComponent(target == .system ? "transaction-system.json" : "transaction.json") }
    private var service: String { target == .system ? "Claude Code-credentials" : Keychain.cliService(directory: directory) }
    /// Where the CLI keeps its account record: in the directory when one is named, otherwise `~/.claude.json`.
    private var configFile: URL {
        let inside = directory.appendingPathComponent(".claude.json")
        if target == .dedicated || FileManager.default.fileExists(atPath: inside.path) { return inside }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }
    // The default login's item belongs to the CLI and is reached through its tool. The dedicated one keeps the
    // access it was created with, so existing setups do not start asking for keychain permission.
    private func keychainRead() throws -> Data? {
        target == .system ? try CLIKeychain.read(service: service) : try Keychain.read(service: service, account: NSUserName())
    }
    private func keychainWrite(_ data: Data) throws {
        if target == .system { try CLIKeychain.write(data, service: service) } else { try Keychain.write(data, service: service, account: NSUserName()) }
    }
    private func keychainDelete() throws {
        if target == .system { try CLIKeychain.delete(service: service) } else { try Keychain.delete(service: service, account: NSUserName()) }
    }
    /// Lilt's own folders. `~/.claude` belongs to the CLI and is never created or re-permissioned here.
    private func prepare() throws {
        try Disk.directory(Disk.root)
        if target == .dedicated { try Disk.directory(directory) }
    }
    private struct Stamp: Codable, Equatable { var file: String?; var keychain: String?; var pending: Bool = false }
    private func digest(_ data: Data?) -> String? { data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
    private func readFile() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppFailure("作用域出现符号链接，已暂停。") }
        return try Data(contentsOf: file)
    }
    private func state() throws -> Stamp { try Stamp(file: digest(readFile()), keychain: digest(keychainRead())) }
    private func expected() throws -> Stamp? {
        guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
        return try JSONDecoder().decode(Stamp.self, from: Data(contentsOf: journal))
    }
    func check() throws {
        try prepare()
        let current = try state()
        if let expected = try expected() {
            guard !expected.pending, expected == current else { throw AppFailure("作用域凭据已被外部修改，或上次切换未完成。自动接力已暂停；请检查管理方。") }
        } else if current.file != nil || current.keychain != nil { throw AppFailure("此作用域已有未确认归属的凭据；Lilt 不会覆盖。") }
    }
    /// What the CLI currently holds for this scope: its keychain item, or the fallback file.
    func currentCredential() throws -> Credential? {
        guard let data = try keychainRead() ?? readFile() else { return nil }
        return Credential(data: data)
    }
    /// Take the scope as it is now for the baseline. Only after the caller has saved what is there.
    func rebaseline() throws {
        try prepare()
        // The CLI keeps its login in the keychain. Bring the fallback file along so an old token is not left lying in it.
        if let held = try keychainRead(), let onDisk = try readFile(), onDisk != held { try Disk.write(held, to: file) }
        try Disk.write(JSONEncoder().encode(try state()), to: journal)
    }
    /// A switch that started and did not finish. Nothing is taken in automatically while this is set.
    var transactionPending: Bool { ((try? expected()) ?? nil)?.pending == true }

    /// `oauthAccount` from a CLI config directory, as JSON. Nil when the file or the entry is missing.
    static func identity(in directory: URL) -> Data? { identity(at: directory.appendingPathComponent(".claude.json")) }
    static func identity(at config: URL) -> Data? {
        guard (try? config.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let data = try? Data(contentsOf: config),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: account)
    }
    func readIdentity() -> Data? { Self.identity(at: configFile) }
    /// Tell the CLI whose login is now in the scope, as ORCA does, so `/status` and anything keyed on the account
    /// follow the switch. Only an existing, readable config file is edited; `nil` removes the entry so the CLI
    /// looks the account up itself rather than showing the previous one.
    func writeIdentity(_ identity: Data?) throws {
        let config = configFile
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        guard try config.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppFailure("作用域配置是符号链接，未写入账号身份。") }
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] else { return }
        if let identity, let account = try JSONSerialization.jsonObject(with: identity) as? [String: Any] { object["oauthAccount"] = account }
        else { object.removeValue(forKey: "oauthAccount") }
        // Read and written back at once: the CLI rewrites this file often, so the window stays as short as possible.
        try Disk.write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]), to: config)
    }
    func apply(_ credential: Credential) throws {
        try credential.validate(); try check()
        // The lock lives with Lilt's own data: nothing of Lilt's is left inside ~/.claude.
        let lockURL = target == .system ? Disk.root.appendingPathComponent(".lilt-lock-system") : directory.appendingPathComponent(".lilt-lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppFailure("无法锁定作用域。") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure("另一个 Lilt 实例正在切换。") }
        try check()
        let previous = try state()
        let oldKey = try keychainRead()
        let oldFile = try readFile()
        // On macOS the CLI reads the keychain; the fallback file is kept in step only where one already exists.
        let writesFile = target == .dedicated || oldFile != nil
        var pending = previous; pending.pending = true
        try Disk.write(JSONEncoder().encode(pending), to: journal)
        // Verify the other writer has not changed anything during preparation.
        guard try state() == previous else { throw AppFailure("检测到并发凭据变更，已暂停。") }
        do {
            try keychainWrite(credential.data)
            guard digest(try readFile()) == previous.file else { throw AppFailure("检测到外部写入，已停止。") }
            if writesFile { try Disk.write(credential.data, to: file) }
            let next = try state()
            guard next.keychain == digest(credential.data), !writesFile || next.file == digest(credential.data) else { throw AppFailure("凭据同步不一致，已暂停。") }
            try Disk.write(JSONEncoder().encode(next), to: journal)
        } catch {
            // Roll back only values still matching this transaction. Never replace an external update.
            if digest(try? keychainRead()) == digest(credential.data) {
                if let oldKey { try? keychainWrite(oldKey) } else { try? keychainDelete() }
            }
            if writesFile, digest(try? readFile()) == digest(credential.data) {
                if let oldFile { try? Disk.write(oldFile, to: file) } else { try? FileManager.default.removeItem(at: file) }
            }
            // Leave a pending journal for explicit inspection after any interrupted transaction.
            throw error
        }
    }
    private var launchParts: [String] {
        ["env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN",
         "-u CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR -u CLAUDE_CODE_HOST_CREDS_FILE",
         "CLAUDE_CONFIG_DIR=\(shellQuote(directory.path))",
         "CLAUDE_SECURESTORAGE_CONFIG_DIR=\(shellQuote(directory.path))",
         "claude"]
    }
    var launchCommand: String { launchParts.joined(separator: " ") }
    /// The same command broken at argument boundaries for reading; the clipboard gets the single-line form.
    var launchCommandDisplay: String { launchParts.joined(separator: " \\\n  ") }
}
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
