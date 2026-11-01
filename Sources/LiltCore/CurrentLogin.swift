import Foundation

/// What saving Claude Code's current default login does with it, given the logins Lilt already keeps.
///
/// The login comes from outside Lilt (`/login` in a terminal, another tool), so whose it is must be established
/// before it is filed under a name. The profile endpoint's answer is the evidence; the `oauthAccount` record in the
/// CLI's config is only what the last writer claimed, and a writer that changed the keychain without it would leave
/// the previous owner's name there.
public enum CurrentLoginPlan: Equatable, Sendable {
    /// Exactly this login is already stored for the account.
    case alreadySaved(UUID)
    /// A newer login of an account Lilt keeps. It replaces the stored one; the name stays.
    case replaces(UUID)
    /// A Claude account Lilt does not keep yet.
    case new
    /// The profile endpoint did not answer, and the config names an account Lilt keeps. Replacing that account's
    /// login on the config's word alone could put another account's login under its name, so nothing is saved.
    case unconfirmed(UUID)

    /// - Parameters:
    ///   - identical: the account whose stored login is byte for byte this one, if any.
    ///   - verified: the identity the profile endpoint returned for this login, nil when it could not be asked.
    ///   - recorded: the `oauthAccount` record beside the login.
    ///   - kept: the identities stored with Lilt's accounts.
    public static func decide(identical: UUID?, verified: OAuthDocument.Identity?, recorded: OAuthDocument.Identity,
                              kept: [(id: UUID, identity: OAuthDocument.Identity)]) -> CurrentLoginPlan {
        if let identical { return .alreadySaved(identical) }
        func owner(_ identity: OAuthDocument.Identity) -> UUID? {
            guard let account = identity.account else { return nil }
            return kept.first { $0.identity.account == account }?.id
        }
        if let verified {
            return owner(verified).map(CurrentLoginPlan.replaces) ?? .new
        }
        return owner(recorded).map(CurrentLoginPlan.unconfirmed) ?? .new
    }

    /// The `oauthAccount` record to keep with the login. The config's record carries more (names, roles) than the
    /// profile answer, so it is kept when it does not contradict the verified identity; otherwise the verified one is.
    public static func identityRecord(verified: Data?, recorded: Data?) -> Data? {
        guard let verified else { return recorded }
        let proven = OAuthDocument.Identity(oauthAccount: verified)
        let claimed = OAuthDocument.Identity(oauthAccount: recorded)
        guard recorded != nil, claimed.account != nil, !claimed.contradicts(proven) else { return verified }
        return recorded
    }
}

/// The link the official CLI prints for signing in by hand ("If the browser didn't open, visit: …").
public enum LoginLink {
    /// The first sign-in link in the CLI's output so far, or nil until one has been printed in full. Terminal escape
    /// sequences are skipped: on a terminal the CLI wraps the link in an OSC 8 hyperlink.
    public static func find(in output: String) -> URL? {
        let stripped = output.replacingOccurrences(of: #"\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        // Only a line that has ended is complete; the link may still be arriving.
        guard let lastBreak = stripped.lastIndex(where: \.isNewline) else { return nil }
        let complete = stripped[..<lastBreak]
        guard let range = complete.range(of: #"https://[^\s\u{1B}\u{07}"'<>]+"#, options: .regularExpression),
              let url = URL(string: String(complete[range])), allowed(url) else { return nil }
        return url
    }
    /// Sign-in pages on Anthropic's own hosts, over HTTPS. Anything else the output might contain is not offered.
    public static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["claude.ai", "claude.com", "anthropic.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
