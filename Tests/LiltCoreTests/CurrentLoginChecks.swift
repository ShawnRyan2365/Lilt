import Foundation
import LiltCore

/// Saving the current login: whose it is decides where it goes, and the sign-in link is read from the CLI's output.
func currentLoginChecks() {
    let kept = UUID(), other = UUID(), same = UUID()
    func identity(_ account: String?) -> OAuthDocument.Identity { OAuthDocument.Identity(account: account) }
    let roster = [(id: kept, identity: identity("fixture-account-a")), (id: other, identity: identity(nil))]

    // The same bytes are the same login, whatever anyone says about it.
    expectEqual(CurrentLoginPlan.decide(identical: same, verified: identity("fixture-account-b"), recorded: identity(nil), kept: roster), .alreadySaved(same))
    // A verified identity Lilt keeps replaces that account's login; one it does not keep is a new account.
    expectEqual(CurrentLoginPlan.decide(identical: nil, verified: identity("fixture-account-a"), recorded: identity("fixture-account-b"), kept: roster), .replaces(kept))
    expectEqual(CurrentLoginPlan.decide(identical: nil, verified: identity("fixture-account-b"), recorded: identity("fixture-account-a"), kept: roster), .new)
    // A verified answer without an account id matches nobody, not the entry that has none.
    expectEqual(CurrentLoginPlan.decide(identical: nil, verified: identity(nil), recorded: identity(nil), kept: roster), .new)
    // Unverified, the config's word is never enough to replace a kept account's login.
    expectEqual(CurrentLoginPlan.decide(identical: nil, verified: nil, recorded: identity("fixture-account-a"), kept: roster), .unconfirmed(kept))
    expectEqual(CurrentLoginPlan.decide(identical: nil, verified: nil, recorded: identity("fixture-account-c"), kept: roster), .new)

    let verified = Data(#"{"accountUuid":"fixture-account-a"}"#.utf8)
    let fuller = Data(#"{"accountUuid":"fixture-account-a","displayName":"fixture"}"#.utf8)
    let stale = Data(#"{"accountUuid":"fixture-account-b","displayName":"fixture"}"#.utf8)
    expectEqual(CurrentLoginPlan.identityRecord(verified: verified, recorded: fuller), fuller)
    expectEqual(CurrentLoginPlan.identityRecord(verified: verified, recorded: stale), verified)
    expectEqual(CurrentLoginPlan.identityRecord(verified: verified, recorded: nil), verified)
    expectEqual(CurrentLoginPlan.identityRecord(verified: nil, recorded: stale), stale)

    let link = "https://claude.ai/oauth/authorize?code=true&client_id=fixture&state=fixture-state"
    let plain = "Opening browser to sign in\u{2026}\nIf the browser didn't open, visit: \(link)\nPaste code here if prompted > "
    expectEqual(LoginLink.find(in: plain)?.absoluteString, link)
    // On a terminal the CLI wraps the link in an OSC 8 hyperlink.
    let wrapped = "If the browser didn't open, visit: \u{1B}]8;;\(link)\u{07}\u{1B}[94m\(link)\u{1B}[39m\u{1B}]8;;\u{07}\n"
    expectEqual(LoginLink.find(in: wrapped)?.absoluteString, link)
    // A line still arriving is not offered, nor a link to anywhere but Anthropic's hosts.
    expect(LoginLink.find(in: "If the browser didn't open, visit: \(link.prefix(30))") == nil)
    expect(LoginLink.find(in: "visit: https://claude.ai.example.invalid/oauth\n") == nil)
    expect(LoginLink.find(in: "visit: http://claude.ai/oauth\n") == nil)
    expectEqual(LoginLink.find(in: "Sign in at: https://platform.claude.com/oauth/authorize?x=1\n")?.host, "platform.claude.com")
}
