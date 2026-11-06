import Foundation

/// A complete Claude OAuth login, either in the official CLI's document or an account wrapper carrying `credentials`.
public enum OAuthCredentialFile {
    public static let maximumBytes = 64 * 1024

    public struct Parsed: Sendable {
        public var credential: Data
        public var identity: Data?
        public var suggestedLabel: String?
    }

    public static func parse(_ data: Data) throws -> Data { try parseDocument(data).credential }

    public static func parseDocument(_ data: Data) throws -> Parsed {
        guard !data.isEmpty, data.count <= maximumBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ImportFailure("请选择有效的 Claude 登录凭证 JSON 文件（不超过 64 KB）。")
        }
        if Set(root.keys) == ["claudeAiOauth"], let oauth = root["claudeAiOauth"] as? [String: Any] {
            return Parsed(credential: try officialDocument(oauth), identity: nil, suggestedLabel: nil)
        }
        if let wrapped = root["credentials"] as? [String: Any] {
            return try wrappedDocument(wrapped, root: root)
        }
        throw ImportFailure("请选择有效的 Claude 登录凭证 JSON 文件（不超过 64 KB）。")
    }

    private static func officialDocument(_ oauth: [String: Any]) throws -> Data {
        guard validToken(oauth["accessToken"], prefix: "sk-ant-oat"),
              validToken(oauth["refreshToken"], prefix: "sk-ant-ort") else {
            throw ImportFailure("文件里没有完整的 Claude OAuth 登录，需要有效的 accessToken 和 refreshToken。")
        }
        guard let milliseconds = number(oauth["expiresAt"]), milliseconds > 0, milliseconds.rounded() == milliseconds,
              let scopes = stringArray(oauth["scopes"]), !scopes.isEmpty,
              optionalText(oauth["subscriptionType"]), optionalText(oauth["rateLimitTier"]) else {
            throw ImportFailure("登录凭证的过期时间、权限范围或订阅字段格式无效。")
        }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    private static func wrappedDocument(_ wrapped: [String: Any], root: [String: Any]) throws -> Parsed {
        guard validToken(wrapped["access_token"], prefix: "sk-ant-oat"),
              validToken(wrapped["refresh_token"], prefix: "sk-ant-ort"),
              let seconds = number(wrapped["expires_at"]), seconds > 0, seconds.rounded() == seconds,
              let scope = text(wrapped["scope"]) else {
            throw ImportFailure("包装凭据需要有效的 access_token、refresh_token、expires_at 和 scope。")
        }
        let scopes = scope.split(separator: " ").map(String.init)
        guard !scopes.isEmpty else { throw ImportFailure("登录凭证的权限范围为空。") }
        let milliseconds = seconds * 1000
        guard milliseconds.isFinite, milliseconds <= Double(Int64.max) else {
            throw ImportFailure("登录凭证的过期时间格式无效。")
        }
        var oauth: [String: Any] = [
            "accessToken": wrapped["access_token"]!,
            "refreshToken": wrapped["refresh_token"]!,
            "expiresAt": Int64(milliseconds),
            "scopes": scopes,
            "subscriptionType": NSNull(),
            "rateLimitTier": NSNull()
        ]
        if let type = text(wrapped["token_type"]) { oauth["tokenType"] = type }
        var identity: [String: Any] = [:]
        if let account = text(wrapped["account_uuid"]) { identity["accountUuid"] = account }
        if let email = text(wrapped["email_address"]) { identity["emailAddress"] = email }
        if let organization = text(wrapped["org_uuid"]) { identity["organizationUuid"] = organization }
        let label = text(root["name"]) ?? text(root["email"])
        return Parsed(credential: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]),
                      identity: identity.isEmpty ? nil : try JSONSerialization.data(withJSONObject: identity),
                      suggestedLabel: label)
    }

    private static func validToken(_ value: Any?, prefix: String) -> Bool {
        guard let token = value as? String, token.hasPrefix(prefix), token.count > 24 else { return false }
        return !token.contains(where: \.isWhitespace)
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    private static func number(_ value: Any?) -> Double? {
        if let value, !(value is Bool), let number = value as? NSNumber {
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let string = text(value), let result = Double(string), result.isFinite { return result }
        return nil
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [String] else { return nil }
        return values.allSatisfy { !$0.isEmpty && !$0.contains(where: \.isWhitespace) } ? values : nil
    }

    private static func optionalText(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is String
    }
}
