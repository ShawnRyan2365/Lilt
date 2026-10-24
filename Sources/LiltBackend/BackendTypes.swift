import Foundation
import LiltCore

public struct BackendFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct ScopeUnreadable: Error, Sendable {
    public let message: String
    public init(_ error: Error) { message = (error as? BackendFailure)?.message ?? "读取失败，稍后重试。" }
}

public struct Credential: Sendable {
    public var data: Data
    public init(data: Data) { self.data = data }
    public var object: [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
    public var oauth: [String: Any] { object["claudeAiOauth"] as? [String: Any] ?? [:] }
    public var token: String? { oauth["accessToken"] as? String }
    public var expiresAt: Date? { (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
    public var refreshable: Bool { !((oauth["refreshToken"] as? String) ?? "").isEmpty }
    public var accessExpired: Bool { expires(within: 0) }
    public func expires(within seconds: TimeInterval) -> Bool { expiresAt.map { $0 <= Date.now.addingTimeInterval(seconds) } ?? false }
    public func validate() throws {
        guard let token, !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw BackendFailure("凭据格式无效，请重新授权或替换 Token。") }
        if accessExpired, !refreshable { throw BackendFailure("凭据已过期，请重新授权。") }
    }
    public static func manual(_ token: String) throws -> Credential {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("sk-ant-oat"), token.count > 24, !token.contains(where: { $0.isWhitespace }) else {
            throw BackendFailure("请输入 Claude setup-token 生成的 OAuth Token；不接受 API Key。")
        }
        return Credential(data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token, "scopes": ["user:inference"]]]))
    }
}

public enum SHA256 {
    private static let initial: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private static let k: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]
    public static func hex(_ data: Data) -> String {
        var bytes = [UInt8](data)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitCount >> ($0 * 8)) })
        var hash = initial
        for start in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let p = start + i * 4
                w[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p+1]) << 16 | UInt32(bytes[p+2]) << 8 | UInt32(bytes[p+3])
            }
            for i in 16..<64 {
                let s0 = w[i-15].rotate(right: 7) ^ w[i-15].rotate(right: 18) ^ (w[i-15] >> 3)
                let s1 = w[i-2].rotate(right: 17) ^ w[i-2].rotate(right: 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a=hash[0], b=hash[1], c=hash[2], d=hash[3], e=hash[4], f=hash[5], g=hash[6], h=hash[7]
            for i in 0..<64 {
                let s1 = e.rotate(right: 6) ^ e.rotate(right: 11) ^ e.rotate(right: 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = a.rotate(right: 2) ^ a.rotate(right: 13) ^ a.rotate(right: 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                h=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
            }
            hash = [hash[0]&+a,hash[1]&+b,hash[2]&+c,hash[3]&+d,hash[4]&+e,hash[5]&+f,hash[6]&+g,hash[7]&+h]
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }
}

private extension UInt32 {
    func rotate(right amount: UInt32) -> UInt32 { (self >> amount) | (self << (32 - amount)) }
}

public struct BackendPaths: Sendable {
    public let home: URL
    public let dataRoot: URL
    public let stateRoot: URL
    public let configRoot: URL
    public let runtimeDirectory: URL
    public let socket: URL
    public let claudeDirectory: URL
    public let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let resolvedHome = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        func xdg(_ key: String, _ fallback: String) -> URL {
            if let value = environment[key], value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true) }
            return resolvedHome.appendingPathComponent(fallback, isDirectory: true)
        }
        let resolvedData = xdg("XDG_DATA_HOME", ".local/share").appendingPathComponent("lilt", isDirectory: true)
        let resolvedState = xdg("XDG_STATE_HOME", ".local/state").appendingPathComponent("lilt", isDirectory: true)
        let resolvedRuntime = environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("lilt", isDirectory: true) : nil }
            ?? resolvedState.appendingPathComponent("run", isDirectory: true)
        home = resolvedHome
        dataRoot = resolvedData
        stateRoot = resolvedState
        configRoot = xdg("XDG_CONFIG_HOME", ".config").appendingPathComponent("lilt", isDirectory: true)
        runtimeDirectory = resolvedRuntime
        socket = resolvedRuntime.appendingPathComponent("lilt.sock")
        claudeDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? resolvedHome.appendingPathComponent(".claude", isDirectory: true)
    }
    public var globalClaudeConfig: URL {
        let environment = self.environment["CLAUDE_CONFIG_DIR"]
        let base = environment.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? home
        let modern = base.appendingPathComponent(".claude.json")
        let legacy = claudeDirectory.appendingPathComponent(".config.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: legacy.path),
           (attributes[.type] as? FileAttributeType) == .typeRegular {
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 || (!FileManager.default.fileExists(atPath: modern.path) && FileManager.default.isWritableFile(atPath: legacy.path)) { return legacy }
        }
        return modern
    }
    public var credentials: URL { claudeDirectory.appendingPathComponent(".credentials.json") }
    public var settings: URL { claudeDirectory.appendingPathComponent("settings.json") }
    public var unit: URL { configRoot.deletingLastPathComponent().appendingPathComponent("systemd/user/liltd.service") }
}

public final class BackendStore: @unchecked Sendable {
    public let paths: BackendPaths
    public init(paths: BackendPaths = BackendPaths()) { self.paths = paths }
    public func prepare() throws {
        for root in [paths.dataRoot, paths.stateRoot, paths.configRoot, paths.runtimeDirectory, paths.dataRoot.appendingPathComponent("secrets", isDirectory: true)] {
            try SecureFiles.directory(root)
        }
    }
    public func load() throws -> Library {
        try prepare()
        let file = paths.dataRoot.appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Library() }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: file))
    }
    public func save(_ library: Library) throws {
        try prepare()
        try SecureFiles.write(try JSONEncoder().encode(library), to: paths.dataRoot.appendingPathComponent("accounts.json"))
    }
    private func secret(_ name: String) throws -> URL {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else { throw BackendFailure("凭据名称无效。") }
        return paths.dataRoot.appendingPathComponent("secrets", isDirectory: true).appendingPathComponent(name)
    }
    public func readSecret(_ name: String) throws -> Data? {
        let file = try secret(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw BackendFailure("凭据文件是符号链接，已拒绝读取。") }
        return try Data(contentsOf: file)
    }
    public func writeSecret(_ name: String, data: Data) throws {
        try prepare()
        try SecureFiles.write(data, to: try secret(name))
    }
    public func deleteSecret(_ name: String) throws {
        let file = try secret(name)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public func hasSecret(_ name: String) -> Bool { (try? readSecret(name)) != nil }
    public func log(_ kind: String, detail: String? = nil) {
        let line = Date.now.formatted(.iso8601) + " " + kind + (detail.map { " " + $0.replacingOccurrences(of: "\n", with: " ") } ?? "") + "\n"
        let file = paths.stateRoot.appendingPathComponent("switches.log")
        let kept = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").suffix(199).map { $0 + "\n" }.joined()
        try? SecureFiles.write(Data((kept + line).utf8), to: file)
    }
}

public func backendReason(_ error: Error) -> String {
    switch error {
    case let failure as BackendFailure: failure.message
    case let failure as ScopeUnreadable: failure.message
    case let failure as UsageFailure: failure.message
    default: "操作失败，请稍后重试。"
    }
}
