import Foundation
import LiltCore

final class RelayTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot(_ first: Double?, _ second: Double?, age: Double = 0) -> UsageSnapshot {
        UsageSnapshot(fiveHour: first.map { UsageWindow(used: 100 - $0) }, sevenDay: second.map { UsageWindow(used: 100 - $0) }, sampledAt: now.addingTimeInterval(-age))
    }
    func testThresholdBoundaries() {
        expectFalse(snapshot(1.1, 80).exhausted(threshold: 1, at: now))
        expect(snapshot(1, 80).exhausted(threshold: 1, at: now))
        expect(snapshot(0.9, 80).exhausted(threshold: 1, at: now))
    }
    func testMissingStaleFutureAndPartial() {
        expectFalse(snapshot(nil, nil).exhausted(threshold: 1, at: now))
        expectFalse(snapshot(0, 0, age: 61).exhausted(threshold: 1, at: now))
        expectFalse(snapshot(0, 0, age: -1).exhausted(threshold: 1, at: now))
        expect(snapshot(nil, 1).exhausted(threshold: 1, at: now))
        expectFalse(snapshot(90, nil).available(threshold: 1, at: now))
    }
    func testLastKnownIsDisplayOnly() {
        let stale = snapshot(0.5, 40, age: 61)
        expectEqual(stale.lastKnownRemaining(stale.fiveHour, at: now), 0.5)
        expectEqual(stale.validRemaining(stale.fiveHour, at: now), nil)
        expectFalse(stale.exhausted(threshold: 1, at: now)); expectFalse(stale.available(threshold: 1, at: now))
        let future = snapshot(50, 50, age: -1)
        expectEqual(future.lastKnownRemaining(future.fiveHour, at: now), nil)
        let reset = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now), sampledAt: now.addingTimeInterval(-300))
        expectEqual(reset.lastKnownRemaining(reset.fiveHour, at: now), nil)
    }
    func testResetDoesNotAssumeRefill() {
        let s = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now), sevenDay: UsageWindow(used: 0), sampledAt: now)
        expectFalse(s.available(threshold: 1, at: now))
        expectFalse(s.exhausted(threshold: 1, at: now))
    }
    func testCandidatesOrderedEnabledFreshAndVerified() {
        var active = Account(label: "Fixture A", kind: .oauth); active.usage = snapshot(1, 70)
        var unknown = Account(label: "Fixture B", kind: .setupToken); unknown.usage = snapshot(99, 99)
        var eligible = Account(label: "Fixture C", kind: .oauth); eligible.usage = snapshot(50, 60); eligible.hotSwitchCapability = .verified
        expectEqual(RelayPolicy().decide(active: active, candidates: [unknown, eligible], at: now), .select(eligible.id))
        eligible.enabled = false
        guard case .pause = RelayPolicy().decide(active: active, candidates: [eligible], at: now) else { fatalError("Expected pause") }
    }
    func testLiveRelayAcceptsUnprovenHotSwitchButNeverUnknownQuota() {
        var active = Account(label: "Fixture A", kind: .oauth); active.usage = snapshot(1, 70)
        var unproven = Account(label: "Fixture B", kind: .oauth); unproven.usage = snapshot(60, 60)
        var tokenOnly = Account(label: "Fixture C", kind: .setupToken); tokenOnly.usageCapability = .unavailable
        var stale = Account(label: "Fixture D", kind: .oauth); stale.usage = snapshot(90, 90, age: 61)
        var refused = Account(label: "Fixture E", kind: .oauth); refused.usage = snapshot(90, 90); refused.hotSwitchCapability = .unavailable
        let live = RelayPolicy(allowUnverifiedHotSwitch: true)
        // The strict rule still refuses an unproven account; the live rule takes it.
        guard case .pause = RelayPolicy().decide(active: active, candidates: [unproven], at: now) else { fatalError("Expected pause") }
        expectEqual(live.decide(active: active, candidates: [tokenOnly, stale, refused, unproven], at: now), .select(unproven.id))
        // Unreadable, stale and known-broken accounts are never chosen, and each says why.
        guard case .pause = live.decide(active: active, candidates: [tokenOnly, stale, refused], at: now) else { fatalError("Expected pause") }
        expectEqual(live.obstacle(for: tokenOnly, at: now), "读不到额度")
        expectEqual(live.obstacle(for: stale, at: now), "读数不是刚查的")
        expectEqual(live.obstacle(for: refused, at: now), "热切换未验证")
        expectEqual(live.obstacle(for: unproven, at: now), nil)
        // Nothing happens while the account in use is above the threshold.
        active.usage = snapshot(40, 70)
        expectEqual(live.decide(active: active, candidates: [unproven], at: now), .wait)
    }
    func testPreferencesWrittenBeforeAutoRelayStillLoad() throws {
        let old = Data(#"{"threshold":1,"scopeEnabled":true,"shortcutKey":37,"shortcutModifiers":2304}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        expectEqual(decoded.autoRelay, nil); expect(decoded.scopeEnabled); expect(decoded.scopeTarget == nil)
        let current = try JSONDecoder().decode(Preferences.self, from: Data(#"{"threshold":1,"scopeEnabled":true,"shortcutKey":37,"shortcutModifiers":2304,"scopeTarget":"system"}"#.utf8))
        expect(current.scopeTarget == .system)
    }
    // Every token below is a made-up placeholder; none of them has ever been issued.
    func document(access: String, refresh: String?, expiresIn seconds: Double, extra: [String: Any] = [:]) -> Data {
        var login: [String: Any] = ["accessToken": access, "expiresAt": Int64((now.timeIntervalSince1970 + seconds) * 1000), "scopes": ["user:inference", "user:profile"]]
        if let refresh { login["refreshToken"] = refresh }
        login.merge(extra) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": login, "untouched": true])
    }
    func testRenewalKeepsTheRestOfTheDocument() {
        let stored = document(access: "fixture-access-old", refresh: "fixture-refresh-old", expiresIn: -60, extra: ["subscriptionType": "fixture-plan"])
        let rotated = OAuthDocument.renewed(stored, response: Data(#"{"access_token":"fixture-access-new","refresh_token":"fixture-refresh-new","expires_in":28800,"scope":"user:inference user:profile"}"#.utf8), now: now)!
        expectEqual(OAuthDocument.accessToken(rotated), "fixture-access-new")
        expectEqual(OAuthDocument.refreshToken(rotated), "fixture-refresh-new")
        expectEqual(OAuthDocument.expiry(rotated), now.addingTimeInterval(28800))
        expectEqual(OAuthDocument.scopes(rotated), ["user:inference", "user:profile"])
        let whole = try! JSONSerialization.jsonObject(with: rotated) as! [String: Any]
        expectEqual(whole["untouched"] as? Bool, true)
        expectEqual((whole["claudeAiOauth"] as! [String: Any])["subscriptionType"] as? String, "fixture-plan")
        // No new refresh token in the answer: the old one stays, as the official CLI does.
        let kept = OAuthDocument.renewed(stored, response: Data(#"{"access_token":"fixture-access-new","expires_in":3600}"#.utf8), now: now)!
        expectEqual(OAuthDocument.refreshToken(kept), "fixture-refresh-old")
        // An answer without an access token changes nothing.
        expect(OAuthDocument.renewed(stored, response: Data(#"{"error":"invalid_grant"}"#.utf8), now: now) == nil)
        expect(OAuthDocument.renewed(stored, response: Data("not json".utf8), now: now) == nil)
    }
    func testReadBackOnlyAdoptsWhatIsProvablyTheSameLogin() {
        let stored = document(access: "fixture-access-a1", refresh: "fixture-refresh-a1", expiresIn: 60)
        let me = OAuthDocument.Identity(oauthAccount: Data(#"{"accountUuid":"FIXTURE-ACCOUNT-A","emailAddress":"a@example.invalid","organizationUuid":"fixture-org"}"#.utf8))
        let other = OAuthDocument.Identity(oauthAccount: Data(#"{"accountUuid":"fixture-account-b","emailAddress":"b@example.invalid"}"#.utf8))
        let nobody = OAuthDocument.Identity(oauthAccount: nil)
        expectEqual(me.account, "fixture-account-a"); expect(nobody.isEmpty)
        expectEqual(OAuthDocument.readBack(stored: stored, runtime: stored, storedIdentity: me, runtimeIdentity: me), .unchanged)
        // Same refresh token, newer access token: a plain renewal, even with no identity on record.
        let sameRefresh = document(access: "fixture-access-a2", refresh: "fixture-refresh-a1", expiresIn: 28800)
        expectEqual(OAuthDocument.readBack(stored: stored, runtime: sameRefresh, storedIdentity: nobody, runtimeIdentity: nobody), .adopt)
        // Rotated refresh token: only a matching account id proves it.
        let rotated = document(access: "fixture-access-a2", refresh: "fixture-refresh-a2", expiresIn: 28800)
        expectEqual(OAuthDocument.readBack(stored: stored, runtime: rotated, storedIdentity: me, runtimeIdentity: me), .adopt)
        expectEqual(OAuthDocument.readBack(stored: stored, runtime: rotated, storedIdentity: nobody, runtimeIdentity: me), .unverifiable)
        expectEqual(OAuthDocument.readBack(stored: stored, runtime: rotated, storedIdentity: me, runtimeIdentity: nobody), .unverifiable)
        // Someone logged in as another account inside the scope.
        expectEqual(OAuthDocument.readBack(stored: stored, runtime: rotated, storedIdentity: me, runtimeIdentity: other), .foreign)
        expectEqual(OAuthDocument.readBack(stored: stored, runtime: sameRefresh, storedIdentity: me, runtimeIdentity: other), .foreign)
        // Older than what is stored, or nothing to renew with: never taken automatically.
        let older = document(access: "fixture-access-a0", refresh: "fixture-refresh-a1", expiresIn: -3600)
        expectEqual(OAuthDocument.readBack(stored: stored, runtime: older, storedIdentity: me, runtimeIdentity: me), .unverifiable)
        let token = document(access: "fixture-long-lived", refresh: nil, expiresIn: 86400)
        expectEqual(OAuthDocument.readBack(stored: token, runtime: rotated, storedIdentity: nobody, runtimeIdentity: nobody), .unverifiable)
        // The profile answer becomes the same record the CLI keeps, and reads back as the same identity.
        let record = OAuthDocument.identityRecord(fromProfile: Data(#"{"account":{"uuid":"fixture-account-a","email":"a@example.invalid","display_name":"Fixture"},"organization":{"uuid":"fixture-org"}}"#.utf8))
        expectEqual(OAuthDocument.Identity(oauthAccount: record), me)
        expect(OAuthDocument.identityRecord(fromProfile: Data(#"{"organization":{"uuid":"fixture-org"}}"#.utf8)) == nil)
    }
    func testStatusLineReadingsAreParsedAndMatchedToTheirAccount() {
        let record = Data(#"{"at":1800000000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800003600},"seven_day":{"used_percentage":41.200000000000003,"resets_at":1800300000}}}"#.utf8)
        let live = UsageParser.parseStatusLine(record)!
        expectEqual(live.sampledAt, now)
        expectEqual(live.fiveHour?.remaining, 76.5)
        expectEqual(live.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1800300000))
        expectEqual(live.source, UsageParser.statusLineSource)
        for bad in ["garbage", "{}", #"{"at":1800000000}"#, #"{"at":1800000000,"rate_limits":{}}"#, #"{"at":1800000000,"rate_limits":{"five_hour":{"used_percentage":true}}}"#] {
            expect(UsageParser.parseStatusLine(Data(bad.utf8)) == nil)
        }
        // Same account: windows reset at the same moments, give or take rounding.
        let known = UsageSnapshot(fiveHour: UsageWindow(used: 20, resetsAt: now.addingTimeInterval(3540)), sevenDay: UsageWindow(used: 40, resetsAt: now.addingTimeInterval(300000)), sampledAt: now.addingTimeInterval(-300))
        expect(live.sharesWindows(with: known, at: now))
        // A session still on another account: its windows reset at other times.
        let other = UsageSnapshot(fiveHour: UsageWindow(used: 90, resetsAt: now.addingTimeInterval(9000)), sevenDay: UsageWindow(used: 10, resetsAt: now.addingTimeInterval(500000)), sampledAt: now)
        expectFalse(live.sharesWindows(with: other, at: now))
        // Once the known 5-hour window has reset, only the weekly one is compared.
        let rolled = UsageSnapshot(fiveHour: UsageWindow(used: 99, resetsAt: now.addingTimeInterval(-60)), sevenDay: UsageWindow(used: 40, resetsAt: now.addingTimeInterval(300000)), sampledAt: now.addingTimeInterval(-3000))
        expect(live.sharesWindows(with: rolled, at: now))
        // Nothing left to compare: not accepted.
        let blind = UsageSnapshot(fiveHour: UsageWindow(used: 20), sevenDay: nil, sampledAt: now)
        expectFalse(live.sharesWindows(with: blind, at: now))
    }
    func testDuplicateEventClaimedOnce() {
        var latch = RelayLatch(); let id = UUID(); let s = snapshot(1, 1)
        expect(latch.claim(account: id, snapshot: s)); expectFalse(latch.claim(account: id, snapshot: s))
    }
    func testRetryAfterAndAuthentication() {
        var backoff = Backoff(); backoff.fail(.rateLimited(120), at: now)
        expectEqual(backoff.nextAttempt, now.addingTimeInterval(120))
        backoff.fail(.authentication, at: now); expectAtLeast(backoff.nextAttempt.timeIntervalSince(now), 900)
        backoff.succeed(); expectEqual(backoff.failures, 0)
    }
    func testParserRejectsMalformedAndBooleanUsage() throws {
        for json in ["{}", "{\"five_hour\":{\"utilization\":true}}", "{\"five_hour\":{\"utilization\":101}}", "{\"five_hour\":{\"utilization\":1,\"resets_at\":\"bad\"}}"] {
            expectThrows(try UsageParser.parse(Data(json.utf8)))
        }
        let s = try UsageParser.parse(Data("{\"five_hour\":{\"utilization\":99},\"seven_day\":null}".utf8), at: now)
        expect(s.exhausted(threshold: 1, at: now)); expectFalse(s.available(threshold: 1, at: now))
    }
}

func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) { precondition(condition(), "Check failed", file: file, line: line) }
func expectFalse(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) { precondition(!condition(), "Expected false", file: file, line: line) }
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected equal", file: file, line: line) }
func expectAtLeast<T: Comparable>(_ a: T, _ b: T) { precondition(a >= b) }
func expectThrows<T>(_ body: @autoclosure () throws -> T) { do { _ = try body(); fatalError("Expected error") } catch {} }
@main struct Checks {
    static func main() throws {
        let suite = RelayTests()
        suite.testThresholdBoundaries()
        suite.testMissingStaleFutureAndPartial()
        suite.testLastKnownIsDisplayOnly()
        suite.testResetDoesNotAssumeRefill()
        suite.testCandidatesOrderedEnabledFreshAndVerified()
        suite.testLiveRelayAcceptsUnprovenHotSwitchButNeverUnknownQuota()
        try suite.testPreferencesWrittenBeforeAutoRelayStillLoad()
        suite.testRenewalKeepsTheRestOfTheDocument()
        suite.testReadBackOnlyAdoptsWhatIsProvablyTheSameLogin()
        suite.testStatusLineReadingsAreParsedAndMatchedToTheirAccount()
        suite.testDuplicateEventClaimedOnce()
        suite.testRetryAfterAndAuthentication()
        try suite.testParserRejectsMalformedAndBooleanUsage()
        try storageChecks()
        print("PASS: 13 rule suites + secure storage checks — boundaries, freshness, last-known display, reset, candidates, live relay, stored preferences, token renewal, read-back, status line readings, deduplication, backoff, parsing")
    }
}

func storageChecks() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/Lilt-fixture-" + UUID().uuidString)
    try SecureFiles.directory(root)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("fixture.json")
    try SecureFiles.write(Data("fictional fixture A".utf8), to: file)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    expectEqual((attributes[.posixPermissions] as! NSNumber).intValue, 0o600)
    try SecureFiles.write(Data("fictional fixture B".utf8), to: file)
    expectEqual(try Data(contentsOf: file), Data("fictional fixture B".utf8))
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    expectThrows(try SecureFiles.write(Data("no overwrite".utf8), to: link))
    expectEqual(try Data(contentsOf: file), Data("fictional fixture B".utf8))
    let dangling = root.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: root.appendingPathComponent("absent").path)
    expectThrows(try SecureFiles.write(Data(), to: dangling))
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    expectFalse(names.contains { $0.hasPrefix(".lilt-") })
}
