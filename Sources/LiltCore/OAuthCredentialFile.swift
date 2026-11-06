import Foundation

/// A complete Claude OAuth login exported by the official CLI, rather than Lilt's encrypted account archive.
public enum OAuthCredentialFile {
    public static let maximumBytes = 64 * 1024

    public static func parse(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["claudeAiOauth"],
              let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw ImportFailure("请选择有效的 Claude 登录凭证 JSON 文件（不超过 64 KB）。")
        }
        guard validToken(oauth["accessToken"], prefix: "sk-ant-oat"),
              validToken(oauth["refreshToken"], prefix: "sk-ant-ort") else {
            throw ImportFailure("文件里没有完整的 Claude OAuth 登录，需要有效的 accessToken 和 refreshToken。")
        }
        guard let expiry = oauth["expiresAt"], !(expiry is Bool),
              let milliseconds = (expiry as? NSNumber)?.doubleValue,
              milliseconds.isFinite, milliseconds > 0, milliseconds.rounded() == milliseconds,
              let scopes = oauth["scopes"] as? [String], !scopes.isEmpty,
              scopes.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }),
              optionalText(oauth["subscriptionType"]), optionalText(oauth["rateLimitTier"]) else {
            throw ImportFailure("登录凭证的过期时间、权限范围或订阅字段格式无效。")
        }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    private static func validToken(_ value: Any?, prefix: String) -> Bool {
        guard let token = value as? String, token.hasPrefix(prefix), token.count > 24 else { return false }
        return !token.contains(where: \.isWhitespace)
    }

    private static func optionalText(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is String
    }
}
