import Foundation

/// Only the user's Claude settings are edited. Project settings, managed policy and shell startup files
/// are outside this scope. Values are never exposed in diagnostics.
public enum AuthenticationSettings {
    public static let credentialKeys = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_HOST_CREDS_FILE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"
    ]
    private static let modelKeys = [
        "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL"
    ]
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["env"] == nil || value["env"] is [String: Any] else { throw Failure.invalidSettings }
        return value
    }
    public enum Failure: Error { case invalidSettings }
    public static func hasAPIOverride(_ data: Data) throws -> Bool {
        let value = try object(data)
        let env = value["env"] as? [String: Any] ?? [:]
        if ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].contains(where: { !(env[$0] as? String ?? "").isEmpty }) { return true }
        if let base = env["ANTHROPIC_BASE_URL"] as? String, !base.isEmpty,
           base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != "https://api.anthropic.com" { return true }
        if ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"].contains(where: {
            let flag = String(describing: env[$0] ?? "").lowercased()
            return flag == "1" || flag == "true"
        }) { return true }
        return !(value["apiKeyHelper"] as? String ?? "").isEmpty || value["forceLoginMethod"] as? String == "console"
            || value["apiKey"] != nil || value["apiBaseUrl"] != nil || value["primaryApiKey"] != nil
    }
    /// Return nil for a no-op, preserving the exact bytes and avoiding needless hot reloads.
    public static func subscriptionSettings(_ data: Data) throws -> Data? {
        var value = try object(data)
        let original = value as NSDictionary
        let wasAPI = try hasAPIOverride(data)
        if var env = value["env"] as? [String: Any] {
            for key in credentialKeys { env.removeValue(forKey: key) }
            if wasAPI { for key in modelKeys { env.removeValue(forKey: key) } }
            value["env"] = env
        }
        for key in ["apiKeyHelper", "apiKey", "apiBaseUrl", "primaryApiKey"] { value.removeValue(forKey: key) }
        if value["forceLoginMethod"] as? String == "console" { value.removeValue(forKey: "forceLoginMethod") }
        if wasAPI { for key in ["model", "primaryModel", "smallFastModel"] { value.removeValue(forKey: key) } }
        guard !(value as NSDictionary).isEqual(original) else { return nil }
        return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
