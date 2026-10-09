import Foundation

/// Pure operations on the credential document the official CLI stores (`{"claudeAiOauth": {...}}`).
/// Nothing here touches the network, the keychain or the disk, so every rule can be checked with made-up data.
public enum OAuthDocument {
    private static func root(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    private static func oauth(_ data: Data) -> [String: Any]? { root(data)?["claudeAiOauth"] as? [String: Any] }
    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    public static func accessToken(_ data: Data) -> String? { text(oauth(data)?["accessToken"]) }
    public static func refreshToken(_ data: Data) -> String? { text(oauth(data)?["refreshToken"]) }
    public static func scopes(_ data: Data) -> [String] { oauth(data)?["scopes"] as? [String] ?? [] }
    /// When the access token stops working. The CLI stores it as milliseconds since 1970.
    public static func expiry(_ data: Data) -> Date? {
        (oauth(data)?["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    /// The stored document with a token-endpoint response folded in, the way the official CLI does it:
    /// new access token and expiry, the refresh token only when a new one came back, scopes when stated.
    /// Everything else in the document is kept. Nil when the response carries no usable access token.
    public static func renewed(_ document: Data, response: Data, now: Date) -> Data? {
        guard var whole = root(document), var login = whole["claudeAiOauth"] as? [String: Any],
              let answer = root(response), let access = text(answer["access_token"]) else { return nil }
        login["accessToken"] = access
        if let seconds = (answer["expires_in"] as? NSNumber)?.doubleValue, seconds.isFinite, seconds > 0 {
            login["expiresAt"] = Int64(((now.timeIntervalSince1970 + seconds) * 1000).rounded())
        }
        if let refresh = text(answer["refresh_token"]) { login["refreshToken"] = refresh }
        if let scope = text(answer["scope"]) { login["scopes"] = scope.split(separator: " ").map(String.init) }
        whole["claudeAiOauth"] = login
        return try? JSONSerialization.data(withJSONObject: whole)
    }

    /// Who a login belongs to, as the CLI records it under `oauthAccount` in its config file.
    public struct Identity: Equatable, Sendable {
        public var account: String?
        public var email: String?
        public var organization: String?
        public init(account: String? = nil, email: String? = nil, organization: String? = nil) {
            self.account = account; self.email = email; self.organization = organization
        }
        /// From the JSON of an `oauthAccount` object; missing or unreadable data is an empty identity.
        public init(oauthAccount data: Data?) {
            let object = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            func field(_ keys: String...) -> String? { keys.lazy.compactMap { OAuthDocument.text(object[$0])?.lowercased() }.first }
            account = field("accountUuid", "accountId")
            email = field("emailAddress", "email")
            organization = field("organizationUuid", "organizationId")
        }
        public var isEmpty: Bool { account == nil && email == nil && organization == nil }
        /// Both sides name the same kind of thing and the names differ.
        func contradicts(_ other: Identity) -> Bool {
            func differ(_ a: String?, _ b: String?) -> Bool { a != nil && b != nil && a != b }
            return differ(account, other.account) || differ(email, other.email) || differ(organization, other.organization)
        }
    }

    /// The `oauthAccount` fields that say who a login is, from the official profile endpoint's answer
    /// (`{"account": {"uuid", "email"}, "organization": {"uuid"}}`), named the way the CLI names them.
    /// Nil unless the answer carries an account id.
    public static func identityRecord(fromProfile data: Data) -> Data? {
        guard let answer = root(data), let account = answer["account"] as? [String: Any], let id = text(account["uuid"]) else { return nil }
        var record: [String: Any] = ["accountUuid": id]
        if let email = text(account["email"]) { record["emailAddress"] = email }
        if let organization = text((answer["organization"] as? [String: Any])?["uuid"]) { record["organizationUuid"] = organization }
        return try? JSONSerialization.data(withJSONObject: record)
    }

    public enum ReadBack: Equatable, Sendable {
        /// The scope holds exactly what was stored.
        case unchanged
        /// The scope holds a renewal of the stored login: keep it.
        case adopt
        /// It may be a renewal, but nothing proves it. A person has to confirm.
        case unverifiable
        /// The scope now holds a different account.
        case foreign
    }

    /// What the credential found in the scope is, relative to the one stored for the account that was applied there.
    /// Mirrors the order ORCA checks in: a contradiction in identity decides first; an unchanged refresh token is
    /// proof enough; a rotated one needs the same account id on both sides; anything older than what is stored
    /// is never taken.
    public static func readBack(stored: Data, runtime: Data, storedIdentity: Identity, runtimeIdentity: Identity) -> ReadBack {
        if accessToken(stored) == accessToken(runtime), refreshToken(stored) == refreshToken(runtime) { return .unchanged }
        guard accessToken(runtime) != nil else { return .unverifiable }
        if storedIdentity.contradicts(runtimeIdentity) { return .foreign }
        if let before = expiry(stored), let after = expiry(runtime), after < before { return .unverifiable }
        guard let renewedWith = refreshToken(runtime), let original = refreshToken(stored) else { return .unverifiable }
        if renewedWith == original { return .adopt }
        if let account = storedIdentity.account, account == runtimeIdentity.account { return .adopt }
        return .unverifiable
    }
}
