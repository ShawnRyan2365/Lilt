import Foundation
import Security
import CryptoKit
import LiltCore

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
/// The scope could not be read just now: the keychain did not answer (it can stall around sleep and wake) or a file
/// could not be opened. That says nothing about who is logged in, so it must never be taken for an outside change.
struct ScopeUnreadable: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ error: Error) { message = (error as? AppFailure)?.message ?? "读取失败，稍后重试。" }
}
struct DualRuntimeConflict: LocalizedError {
    let message = "检测到钥匙串与本地文件中的登录不一致。为避免 Claude Code 使用另一个账号，已暂停切换；请到“接入”选择要保留的登录。"
    var errorDescription: String? { message }
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
    static func account() throws -> String { try validated(NSUserName()) }
    /// Account names are interpolated into a `security` command. Only the characters a macOS user name
    /// or a Lilt account id can contain are accepted, so a stored label cannot change the command.
    private static func validated(_ account: String) throws -> String {
        guard !account.isEmpty, account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw AppFailure("这个名称不能用作钥匙串条目名。")
        }
        return account
    }
    @discardableResult
    private static func run(_ arguments: [String], input: String? = nil, wait: TimeInterval = 5) throws -> (status: Int32, output: Data) {
        let process = Process(); let output = Pipe(); let stdin = Pipe()
        process.executableURL = tool; process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = stdin
        // Woken by the exit itself rather than by polling, so each call costs what `security` takes and no more.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw AppFailure("无法访问钥匙串。") }
        if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        // A keychain waiting for the user to allow access would otherwise hold Lilt up indefinitely. The wait is measured
        // on a clock that stops while the Mac sleeps: a read the system froze halfway through has not hung.
        if exited.wait(timeout: .now() + wait) == .timedOut { process.terminate(); throw AppFailure("钥匙串没有响应，可能在等你允许访问。") }
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
    }
    static func read(service: String, account explicit: String? = nil, wait: TimeInterval = 5) throws -> Data? {
        let name = try explicit.map { try validated($0) } ?? account()
        let result = try run(["find-generic-password", "-s", service, "-a", name, "-w"], wait: wait)
        if result.status == 44 { return nil }
        guard result.status == 0 else { throw AppFailure("读取钥匙串失败（返回 \(result.status)）。") }
        return KeychainPassword.decode(result.output)
    }
    static func write(_ data: Data, service: String) throws {
        let command = try writeCommand(data, service: service, account: account())
        let result = try run(["-i"], input: command)
        guard result.status == 0 else { throw AppFailure("写入 Claude Code 登录失败（钥匙串返回 \(result.status)）。") }
    }
    /// security -i has a 4096-byte input buffer. Hex doubles a perfectly valid JSON document's size;
    /// a quoted UTF-8 argument preserves the exact bytes without that expansion. This is security's
    /// own parser, not a shell: escape quotes and backslashes, and keep all secrets on stdin.
    static func writeCommand(_ data: Data, service: String, account: String) throws -> String {
        func quote(_ value: String) throws -> String {
            guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
                throw AppFailure("钥匙串条目名称含无效字符。")
            }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let prefix = try "add-generic-password -U -a \(quote(validated(account))) -s \(quote(service))"
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "\(prefix) -X \(hex)\n"
        if command.utf8.count < 3800 { return command }
        if let text = String(data: data, encoding: .utf8), let quoted = try? quote(text) {
            let compact = "\(prefix) -w \(quoted)\n"
            if compact.utf8.count < 3800 { return compact }
        }
        throw AppFailure("登录资料超过系统钥匙串工具的单行写入上限，未截断或丢弃任何凭据。")
    }
    static func delete(service: String, account explicit: String? = nil) throws {
        let name = try explicit.map { try validated($0) } ?? account()
        let result = try run(["delete-generic-password", "-s", service, "-a", name])
        guard result.status == 0 || result.status == 44 else { throw AppFailure("无法删除钥匙串里的临时登录。") }
    }
}
/// Lilt's own copies of account logins and identity records. These used to live in the login keychain
/// under `app.lilt.accounts`. An ad-hoc signature changes on every rebuild, which drops the keychain's
/// "always allow" and asks for the Mac password on the next access — once per account, so every switch
/// asked. A 0600 file in Lilt's own directory does not. The official CLI's login item is untouched.
enum AccountVault {
    private static let directory = Disk.root.appending(component: "secrets", directoryHint: .isDirectory)
    private static func file(_ account: String) throws -> URL {
        guard !account.isEmpty, account.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw AppFailure("凭据名称无效。")
        }
        return directory.appending(component: account, directoryHint: .notDirectory)
    }
    static func hasFile(account: String) -> Bool {
        guard let url = try? file(account), FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }
    static func read(account: String) throws -> Data? {
        let url = try file(account)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppFailure("凭据文件是符号链接，已拒绝读取。") }
            return try Data(contentsOf: url)
        }
        // One-time move. The wait is long enough to type the login password if macOS asks this once.
        guard let legacy = try CLIKeychain.read(service: Keychain.service, account: account, wait: 90) else { return nil }
        try write(legacy, account: account)
        return legacy
    }
    static func write(_ data: Data, account: String) throws {
        let moving = !hasFile(account: account)
        try Disk.directory(directory)
        try Disk.write(data, to: try file(account))
        // The login-keychain copy is what kept prompting. It is only removed after the file is in place, and only when
        // this write is the move: once a file exists, the copy is long gone, and asking again started a process per write.
        if moving { try? CLIKeychain.delete(service: Keychain.service, account: account) }
    }
    static func delete(account: String) throws {
        let url = try file(account)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppFailure("凭据文件是符号链接，没有删除。") }
            try FileManager.default.removeItem(at: url)
        }
        try? CLIKeychain.delete(service: Keychain.service, account: account)
    }
}
struct Disk {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Lilt", directoryHint: .isDirectory)
    /// A file of Lilt's own. Saying it is not a directory spares a disk lookup that `appendingPathComponent` makes.
    static func file(_ name: String) -> URL { root.appending(component: name, directoryHint: .notDirectory) }
    static func directory(_ url: URL) throws { try SecureFiles.directory(url) }
    static func write(_ data: Data, to url: URL) throws { try SecureFiles.write(data, to: url) }
    static func load() throws -> Library {
        try directory(root)
        let path = file("accounts.json")
        if !FileManager.default.fileExists(atPath: path.path) { return Library() }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: path))
    }
    static func save(_ library: Library) throws { try write(JSONEncoder().encode(library), to: file("accounts.json")) }
}

/// Where blocking work goes instead of the main thread: each keychain call starts a `security` process, and each write
/// waits for `fsync`. With many Claude sessions writing to disk at once a plain read took tens of milliseconds, and a
/// switch, made of several of each, froze the window. One serial queue, so reads and writes reach the scope and Lilt's
/// files in the order they were asked for.
enum IOQueue {
    private static let queue = DispatchQueue(label: "app.lilt.io", qos: .userInitiated)
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async { continuation.resume(with: Result { try work() }) } }
    }
    static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
    }
    /// Waits for everything queued, then runs `work`: for a write the caller must know reached the disk, and on quitting.
    static func sync<T>(_ work: () throws -> T) rethrows -> T { try queue.sync(execute: work) }
}

/// When Lilt switched the login, and whether by hand or by relay: the last 200 switches, one line each, in
/// `switches.log`. It is there to set beside errors a Claude Code session reports, such as "Connection lost
/// mid-response", and see whether they follow a switch. A switch or takeover that failed is recorded too, with the
/// error's own text, because the alert that showed it is gone by the time anyone asks why relay stopped. Those texts
/// are Lilt's fixed messages and status codes: no names, tokens or account ids.
enum SwitchLog {
    static func record(_ kind: String, detail: String? = nil, at date: Date = .now) {
        let reason = detail.map { " " + $0.replacingOccurrences(of: "\n", with: " ") } ?? ""
        let line = date.formatted(.iso8601) + " " + kind + reason + "\n"
        Task { await IOQueue.perform {
            let url = Disk.file("switches.log")
            let kept = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").suffix(199).map { $0 + "\n" }.joined()
            try? Disk.write(Data((kept + line).utf8), to: url)
        } }
    }
}

/// The place the official CLI looks for its login, written to as one transaction.
/// `system` is Claude Code's default login (keychain item `Claude Code-credentials`, `~/.claude`, `~/.claude.json`),
/// the same surfaces ORCA writes. `dedicated` is a directory of Lilt's own that only the launch command points at.
/// `AppModel` runs reads and writes one at a time on its I/O queue, including the in-memory store of regression checks.
/// The keychain is authoritative. `.credentials.json` is only the CLI's change signal, never a second runtime login.
final class RuntimeScope: @unchecked Sendable {
    struct CredentialAccess {
        var read: () throws -> Data?
        var write: (Data) throws -> Void
        var delete: () throws -> Void
    }
    enum DualAuthority { case keychain, file }
    let target: ScopeTarget
    let directory: URL
    private let root: URL
    private let home: URL
    private let credentialAccess: CredentialAccess?
    init(target: ScopeTarget) {
        self.target = target
        root = Disk.root; home = FileManager.default.homeDirectoryForCurrentUser; credentialAccess = nil
        directory = target == .system ? FileManager.default.homeDirectoryForCurrentUser.appending(component: ".claude", directoryHint: .isDirectory)
                                       : Disk.root.appending(component: "scope", directoryHint: .isDirectory)
    }
    /// Isolated transaction checks use an in-memory credential store, never a macOS keychain item.
    init(fixtureHome: URL, credentials: CredentialAccess) {
        target = .system; home = fixtureHome; root = fixtureHome.appendingPathComponent("lilt")
        directory = fixtureHome.appendingPathComponent(".claude"); credentialAccess = credentials
    }
    /// What Lilt keeps in `.credentials.json` when the file holds no login of its own: an empty document. The CLI reads
    /// the keychain first and finds nothing in this, so it changes nothing about which login is used; it is there for
    /// its modification time. A running CLI that sees that time change drops every login it has cached and reads the
    /// keychain on its next request. Without the file it keeps what it read from the keychain for up to 30 seconds, so a
    /// busy session went on spending the account just left after a switch, and could run into its limit meanwhile.
    /// (Claude Code 2.1.308, read from its code; not yet measured against running sessions.)
    static let signal = Data("{}".utf8)
    /// A file holding a login rather than Lilt's signal. File mode owns it; keychain mode keeps any existing one in step.
    static func holdsLogin(_ data: Data?) -> Bool {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["claudeAiOauth"] != nil
    }
    private var file: URL { directory.appending(component: ".credentials.json", directoryHint: .notDirectory) }
    private var settingsFile: URL { directory.appending(component: "settings.json", directoryHint: .notDirectory) }
    private func readSettings() throws -> Data? {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return nil }
        guard try settingsFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw AppFailure("Claude 用户配置是符号链接，未修改。")
        }
        do { return try Data(contentsOf: settingsFile) } catch { throw ScopeUnreadable(AppFailure("Claude 用户配置暂时读不出来。")) }
    }
    func hasAPIOverride() throws -> Bool {
        guard let data = try readSettings() else { return false }
        do { return try AuthenticationSettings.hasAPIOverride(data) }
        catch { throw AppFailure("Claude 用户配置格式无效，请修复 settings.json 后再切换。") }
    }
    private var journal: URL { root.appending(component: target == .system ? "transaction-system.json" : "transaction.json", directoryHint: .notDirectory) }
    private var service: String { target == .system ? "Claude Code-credentials" : Keychain.cliService(directory: directory) }
    /// Where the CLI keeps its account record: in the directory when one is named, otherwise `~/.claude.json`.
    private var configFile: URL {
        let inside = directory.appending(component: ".claude.json", directoryHint: .notDirectory)
        if target == .dedicated || FileManager.default.fileExists(atPath: inside.path) { return inside }
        return home.appending(component: ".claude.json", directoryHint: .notDirectory)
    }
    // The default login's item belongs to the CLI and is reached through its tool. The dedicated one keeps the
    // access it was created with, so existing setups do not start asking for keychain permission.
    private func keychainRead() throws -> Data? {
        do {
            if let credentialAccess { return try credentialAccess.read() }
            return target == .system ? try CLIKeychain.read(service: service) : try Keychain.read(service: service, account: NSUserName())
        } catch { throw ScopeUnreadable(error) }
    }
    private func keychainWrite(_ data: Data) throws {
        if let credentialAccess { try credentialAccess.write(data); return }
        if target == .system { try CLIKeychain.write(data, service: service) } else { try Keychain.write(data, service: service, account: NSUserName()) }
    }
    private func keychainDelete() throws {
        if let credentialAccess { try credentialAccess.delete(); return }
        if target == .system { try CLIKeychain.delete(service: service) } else { try Keychain.delete(service: service, account: NSUserName()) }
    }
    /// Lilt's own folders. `~/.claude` belongs to the CLI and is never created or re-permissioned here.
    private func prepare() throws {
        try Disk.directory(root)
        if target == .dedicated { try Disk.directory(directory) }
    }
    private struct Stamp: Codable, Equatable { var file: String?; var keychain: String?; var pending: Bool = false }
    private func digest(_ data: Data?) -> String? { data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } }
    private func readFile() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppFailure("作用域出现符号链接，已暂停。") }
        do { return try Data(contentsOf: file) } catch { throw ScopeUnreadable(AppFailure("登录文件暂时读不出来。")) }
    }
    private func state() throws -> Stamp {
        try Stamp(file: digest(readFile()), keychain: digest(keychainRead()))
    }
    private func expected() throws -> Stamp? {
        guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
        return try JSONDecoder().decode(Stamp.self, from: Data(contentsOf: journal))
    }
    private func ensureNoDual() throws {
        let held = try keychainRead(), onDisk = try readFile()
        if Self.holdsLogin(onDisk), held != onDisk { throw DualRuntimeConflict() }
    }
    func check() throws {
        try prepare(); try ensureNoDual()
        try verify(state())
    }
    private func verify(_ current: Stamp) throws {
        if let expected = try expected() {
            guard !expected.pending, expected == current else { throw AppFailure("作用域凭据已被外部修改，或上次切换未完成。自动接力已暂停；请检查管理方。") }
        } else if current.file != nil || current.keychain != nil { throw AppFailure("此作用域已有未确认归属的凭据；Lilt 不会覆盖。") }
    }
    func currentCredential() throws -> Credential? {
        guard let held = try keychainRead() else { return nil }
        return Credential(data: held)
    }
    func fileCredential() throws -> Credential? {
        guard let onDisk = try readFile(), Self.holdsLogin(onDisk) else { return nil }
        return Credential(data: onDisk)
    }
    func rebaseline() throws {
        try prepare(); try ensureNoDual()
        let held = try keychainRead(), onDisk = try readFile()
        var nextFile = onDisk
        if held != nil || onDisk != nil {
            try Disk.write(Self.signal, to: file); nextFile = Self.signal
        }
        try Disk.write(JSONEncoder().encode(Stamp(file: digest(nextFile), keychain: digest(held))), to: journal)
    }
    /// Take Lilt's signal away when Lilt stops managing the default login, so the CLI goes back to noticing keychain
    /// changes by itself. A file that holds anything else is left alone.
    func removeSignal() {
        guard target == .system, (try? readFile()) == Self.signal else { return }
        try? FileManager.default.removeItem(at: file)
    }
    /// A switch that started and did not finish. Nothing is taken in automatically while this is set, except by `settle`.
    var transactionPending: Bool { ((try? expected()) ?? nil)?.pending == true }
    /// Ends a switch that stopped halfway once the selected storage holds a login Lilt keeps. File mode preserves that
    /// login; keychain mode rewrites the signal if needed. The journal then records the scope as it is.
    func settle() throws {
        try prepare()
        if target == .system, !Self.holdsLogin(try readFile()) { try Disk.write(Self.signal, to: file) }
        try rebaseline()
    }

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
    func resolveDual(using authority: DualAuthority, expected credential: Credential) throws {
        try apply(credential, replacingExternalState: true, resolvingDual: authority)
    }
    func apply(_ credential: Credential, replacingExternalState: Bool = false, resolvingDual: DualAuthority? = nil) throws {
        try credential.validate(); try prepare()
        let lockURL = target == .system ? root.appending(component: ".lilt-lock-system", directoryHint: .notDirectory)
                                        : directory.appending(component: ".lilt-lock", directoryHint: .notDirectory)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppFailure("无法锁定作用域。") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppFailure("另一个 Lilt 实例正在切换。") }
        let oldKey = try keychainRead()
        let oldFile = try readFile()
        if let authority = resolvingDual {
            let current = authority == .keychain ? oldKey : oldFile
            guard current == credential.data else { throw AppFailure("处理期间登录已变化，未应用旧快照；请重新检查。") }
        } else { try ensureNoDual() }
        let previous = Stamp(file: digest(oldFile), keychain: digest(oldKey))
        if !replacingExternalState { try verify(previous) }
        let oldSettings = try readSettings()
        if !replacingExternalState, try oldSettings.map(AuthenticationSettings.hasAPIOverride) == true {
            throw AppFailure("检测到 API 模式，自动接力不会覆盖；请手动选择订阅账号。")
        }
        let newSettings = try replacingExternalState ? oldSettings.flatMap(AuthenticationSettings.subscriptionSettings) : nil
        var wroteFile = false
        var pending = previous; pending.pending = true
        let priorJournal = try? Data(contentsOf: journal)
        try Disk.write(JSONEncoder().encode(pending), to: journal)
        do {
            guard try state() == previous, try readSettings() == oldSettings else { throw AppFailure("检测到并发登录配置变更，已暂停。") }
        } catch {
            if let priorJournal { try? Disk.write(priorJournal, to: journal) } else { try? FileManager.default.removeItem(at: journal) }
            throw error
        }
        do {
            try keychainWrite(credential.data)
            guard digest(try readFile()) == previous.file else { throw AppFailure("检测到外部写入，已停止。") }
            guard try readSettings() == oldSettings else { throw AppFailure("API 配置被其他工具同时修改，请稍后重试。") }
            if let newSettings { try Disk.write(newSettings, to: settingsFile) }
            try Disk.write(Self.signal, to: file); wroteFile = true
            let next = try state()
            guard next.keychain == digest(credential.data), next.file == digest(Self.signal),
                  try readSettings() == (newSettings ?? oldSettings) else { throw AppFailure("登录配置同步不一致，已暂停。") }
            try Disk.write(JSONEncoder().encode(next), to: journal)
        } catch {
            if let newSettings, let oldSettings, (try? readSettings()) == newSettings {
                try? Disk.write(oldSettings, to: settingsFile)
            }
            if digest(try? keychainRead()) == digest(credential.data) {
                if let oldKey { try? keychainWrite(oldKey) } else { try? keychainDelete() }
            }
            if wroteFile, digest(try? readFile()) == digest(Self.signal) {
                if let oldFile { try? Disk.write(oldFile, to: file) } else { try? FileManager.default.removeItem(at: file) }
            }
            if (try? state()) == previous, (try? readSettings()) == oldSettings {
                if let priorJournal { try? Disk.write(priorJournal, to: journal) } else { try? FileManager.default.removeItem(at: journal) }
            }
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
