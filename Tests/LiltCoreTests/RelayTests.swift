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
        var stale = Account(label: "Fixture D", kind: .oauth); stale.usage = snapshot(90, 90, age: 601)
        var refused = Account(label: "Fixture E", kind: .oauth); refused.usage = snapshot(90, 90); refused.hotSwitchCapability = .unavailable
        let live = RelayPolicy(allowUnverifiedHotSwitch: true)
        // The strict rule still refuses an unproven account; the live rule takes it.
        guard case .pause = RelayPolicy().decide(active: active, candidates: [unproven], at: now) else { fatalError("Expected pause") }
        expectEqual(live.decide(active: active, candidates: [tokenOnly, stale, refused, unproven], at: now), .select(unproven.id))
        // Unreadable, stale and known-broken accounts are never chosen, and each says why.
        guard case .pause = live.decide(active: active, candidates: [tokenOnly, stale, refused], at: now) else { fatalError("Expected pause") }
        expectEqual(live.obstacle(for: tokenOnly, at: now), "读不到额度")
        expectEqual(live.obstacle(for: stale, at: now), "额度未确认")
        expectEqual(live.obstacle(for: refused, at: now), "热切换未验证")
        expectEqual(live.obstacle(for: unproven, at: now), nil)
        // Nothing happens while the account in use is above the threshold.
        active.usage = snapshot(40, 70)
        expectEqual(live.decide(active: active, candidates: [unproven], at: now), .wait)
    }
    func testRelayKeepsATriggerWhileOtherAccountsAreRead() {
        var active = Account(label: "Fixture A", kind: .oauth)
        active.usage = snapshot(0, 40, age: 180)
        active.usage?.source = UsageParser.statusLineSource
        var ready = Account(label: "Fixture B", kind: .oauth); ready.usage = snapshot(50, 50)
        let live = RelayPolicy(threshold: 1, allowUnverifiedHotSwitch: true)
        // Three minutes old is no longer "just queried", so a plain decision waits.
        expectEqual(live.decide(active: active, candidates: [ready], at: now), .wait)
        // Once the hand-off has accepted the reading, time spent reading other accounts does not cancel it.
        expect(active.usage!.remainsExhausted(threshold: 1, at: now))
        expectEqual(live.decide(active: active, candidates: [ready], at: now, holdActiveReading: true), .select(ready.id))
        // A window that has already reset is not held open.
        active.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now.addingTimeInterval(-1)), sevenDay: UsageWindow(used: 10), sampledAt: now.addingTimeInterval(-180))
        expectFalse(active.usage!.remainsExhausted(threshold: 1, at: now))
        expectEqual(live.decide(active: active, candidates: [ready], at: now, holdActiveReading: true), .wait)
        // The status line is trusted for five minutes, matching how long the endpoint is left alone.
        expect(snapshot(0, 40, age: 180).exhausted(threshold: 1, at: now, lifetime: 300))
        expectFalse(snapshot(0, 40, age: 301).exhausted(threshold: 1, at: now, lifetime: 300))
    }
    func testSecurityPrintsNonASCIIPasswordsAsHex() {
        let json = Data(#"{"claudeAiOauth":{"accessToken":"fixture-access","displayName":"fixture-name"}}"#.utf8)
        let named = Data(#"{"note":"测试 fixture"}"#.utf8)
        let hex = named.map { String(format: "%02x", $0) }.joined()
        expectEqual(KeychainPassword.decode(Data((hex + "\n").utf8)), named)
        expectEqual(KeychainPassword.decode(json + Data([0x0A])), json)
        // Printed text that is not a hex-encoded JSON object stays as printed.
        let token = Data("fixture-not-hex".utf8)
        expectEqual(KeychainPassword.decode(token), token)
    }
    func testPreferencesWrittenBeforeAutoRelayStillLoad() throws {
        let old = Data(#"{"threshold":1,"scopeEnabled":true,"shortcutKey":37,"shortcutModifiers":2304}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        expectEqual(decoded.autoRelay, nil); expect(decoded.scopeEnabled); expect(decoded.scopeTarget == nil); expectEqual(decoded.soonerWeekly, nil)
        expectEqual(decoded.autoSort, nil)
        let current = try JSONDecoder().decode(Preferences.self, from: Data(#"{"threshold":1,"scopeEnabled":true,"shortcutKey":37,"shortcutModifiers":2304,"scopeTarget":"system","runtimeFileStorage":false}"#.utf8))
        expect(current.scopeTarget == .system)
        let legacyFiles = try JSONDecoder().decode(Preferences.self, from: Data(#"{"threshold":1,"scopeEnabled":true,"shortcutKey":37,"shortcutModifiers":2304,"runtimeFileStorage":true}"#.utf8))
        expect(legacyFiles.scopeEnabled && legacyFiles.scopeTarget == nil)
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
        // A session idle since its last request reports a lower figure for the same window than Lilt already has: the
        // higher one is kept, with the newer reading's time and reset. A higher figure is news and stands as it is.
        let seen = UsageSnapshot(fiveHour: UsageWindow(used: 73, resetsAt: now.addingTimeInterval(3540)), sevenDay: UsageWindow(used: 30, resetsAt: now.addingTimeInterval(300000)), sampledAt: now.addingTimeInterval(-3))
        let kept = live.keepingHigher(than: seen)
        expectEqual(kept.fiveHour?.used, 73); expectEqual(kept.sevenDay?.used, live.sevenDay?.used)
        expectEqual(kept.sampledAt, live.sampledAt); expectEqual(kept.fiveHour?.resetsAt, live.fiveHour?.resetsAt)
        expectEqual(live.keepingHigher(than: known).fiveHour?.used, 23.5)
        // A window that has reset is a new one, and without reset times there is nothing to tell the windows apart by.
        expectEqual(live.keepingHigher(than: rolled).fiveHour?.used, 23.5)
        expectEqual(live.keepingHigher(than: blind).fiveHour?.used, 23.5)
    }
    func testDuplicateEventClaimedOnce() {
        var latch = RelayLatch(); let id = UUID(); let s = snapshot(1, 1)
        expect(latch.claim(account: id, snapshot: s)); expectFalse(latch.claim(account: id, snapshot: s))
        // A hand-off that never started gives the reading back; other readings are untouched.
        let other = snapshot(1, 1, age: 5)
        expect(latch.claim(account: id, snapshot: other))
        latch.release(account: id, snapshot: s)
        expect(latch.claim(account: id, snapshot: s)); expectFalse(latch.claim(account: id, snapshot: other))
    }
    func testRetryAfterAndAuthentication() {
        var backoff = Backoff(); backoff.fail(.rateLimited(120), at: now)
        expectEqual(backoff.nextAttempt, now.addingTimeInterval(120))
        backoff.fail(.authentication, at: now); expectAtLeast(backoff.nextAttempt.timeIntervalSince(now), 900)
        backoff.succeed(); expectEqual(backoff.failures, 0)
        backoff.fail(.rateLimited(0), at: now)
        expectEqual(backoff.nextAttempt, now.addingTimeInterval(300))
        var bounded = Backoff(); bounded.fail(.rateLimited(86400), at: now)
        expectEqual(bounded.nextAttempt, now.addingTimeInterval(4500))
    }
    func testUsagePollingKeepsAlternatesAndResetsMoving() {
        var active = Account(label: "Active", kind: .oauth)
        active.lastChecked = now
        expectFalse(UsagePolling.due(active, active: true, autoRelay: true, urgent: false, watching: true, at: now.addingTimeInterval(179)))
        expect(UsagePolling.due(active, active: true, autoRelay: true, urgent: false, watching: true, at: now.addingTimeInterval(180)))
        expectFalse(UsagePolling.due(active, active: true, autoRelay: true, urgent: true, watching: true, at: now.addingTimeInterval(59)))
        expect(UsagePolling.due(active, active: true, autoRelay: true, urgent: true, watching: true, at: now.addingTimeInterval(60)))
        var alternate = Account(label: "Alternate", kind: .oauth)
        alternate.lastChecked = now
        expectFalse(UsagePolling.due(alternate, active: false, autoRelay: false, urgent: false, watching: true, at: now.addingTimeInterval(299)))
        expect(UsagePolling.due(alternate, active: false, autoRelay: false, urgent: false, watching: true, at: now.addingTimeInterval(300)))
        expectFalse(UsagePolling.due(alternate, active: false, autoRelay: false, urgent: false, watching: false, at: now.addingTimeInterval(599)))
        expect(UsagePolling.due(alternate, active: false, autoRelay: false, urgent: false, watching: false, at: now.addingTimeInterval(600)))
        alternate.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now.addingTimeInterval(10)), sampledAt: now)
        expectFalse(UsagePolling.due(alternate, active: false, autoRelay: false, urgent: false, watching: false, at: now.addingTimeInterval(14)))
        expect(UsagePolling.due(alternate, active: false, autoRelay: false, urgent: false, watching: false, at: now.addingTimeInterval(15)))
        active.usage = UsageSnapshot(fiveHour: UsageWindow(used: 20), sampledAt: now, source: UsageParser.statusLineSource)
        active.lastChecked = now.addingTimeInterval(-3600)
        expectFalse(UsagePolling.due(active, active: true, autoRelay: true, urgent: false, watching: true, at: now.addingTimeInterval(59)))
        expect(UsagePolling.due(active, active: true, autoRelay: true, urgent: false, watching: true, at: now.addingTimeInterval(60)))
        let earlier = UsageSnapshot(fiveHour: UsageWindow(used: 90), sampledAt: now.addingTimeInterval(-240))
        let latest = UsageSnapshot(fiveHour: UsageWindow(used: 98.8), sampledAt: now.addingTimeInterval(-120))
        expectEqual(UsagePolling.paceLifetime(of: latest), 180)
        let seconds = UsagePace.secondsToThreshold(latest, after: [earlier, latest], threshold: 1, at: now,
                                                   lifetime: UsagePolling.paceLifetime(of: latest))
        expect(seconds != nil && seconds! <= RelayPolicy.confirmLifetime)
        expectEqual(UsagePolling.paceLifetime(of: active.usage!), 300)
        alternate.enabled = false
        expectFalse(UsagePolling.due(alternate, active: false, autoRelay: false, urgent: false, watching: true, at: now.addingTimeInterval(3600)))
    }
    func testParserRejectsMalformedAndBooleanUsage() throws {
        for json in ["{}", "{\"five_hour\":{\"utilization\":true}}", "{\"five_hour\":{\"utilization\":101}}", "{\"five_hour\":{\"utilization\":1,\"resets_at\":\"bad\"}}"] {
            expectThrows(try UsageParser.parse(Data(json.utf8)))
        }
        let s = try UsageParser.parse(Data("{\"five_hour\":{\"utilization\":99},\"seven_day\":null}".utf8), at: now)
        expect(s.exhausted(threshold: 1, at: now)); expectFalse(s.available(threshold: 1, at: now))
    }
    /// Ten minutes is twice Claude Code's own five-minute refresh buffer. The default threshold stays 1%.
    func testRenewalLeadIsTwiceTheCLIBuffer() {
        expectEqual(RelayPolicy.renewalLead, 600)
        expectEqual(RelayPolicy().threshold, 1)
        expectEqual(Preferences().threshold, 1)
        expectFalse(Preferences().soonerWeekly == true)
    }
    /// A rejected refresh token stays out of automatic relay even when a later sample looks plentiful.
    /// Clearing the flag is what reauthorization does. A network message alone does not isolate anyone.
    func testRejectedRefreshLeavesAutomaticRelayUntilReauthorized() throws {
        var active = Account(label: "Fixture A", kind: .oauth)
        active.usage = snapshot(1, 70)
        var rejected = Account(label: "Fixture B", kind: .oauth)
        rejected.hotSwitchCapability = .verified
        rejected.usage = snapshot(90, 90)
        rejected.refreshRejected = true
        let policy = RelayPolicy(allowUnverifiedHotSwitch: true)
        expectEqual(policy.obstacle(for: rejected, at: now), "需重新授权")
        rejected.usage = snapshot(99, 99)
        expectEqual(policy.obstacle(for: rejected, at: now), "需重新授权")
        var open = Account(label: "Fixture C", kind: .oauth)
        open.hotSwitchCapability = .verified
        open.usage = snapshot(40, 40)
        expectEqual(policy.decide(active: active, candidates: [rejected, open], at: now), .select(open.id))
        guard case .pause = policy.decide(active: active, candidates: [rejected], at: now) else { fatalError("Expected pause") }
        rejected.refreshRejected = nil
        expectEqual(policy.obstacle(for: rejected, at: now), nil)
        expectEqual(policy.decide(active: active, candidates: [rejected], at: now), .select(rejected.id))
        let old = Data(#"{"id":"00000000-0000-0000-0000-000000000001","label":"Fixture","kind":"oauth","enabled":true,"usageCapability":"unknown","hotSwitchCapability":"unknown"}"#.utf8)
        expectEqual(try JSONDecoder().decode(Account.self, from: old).refreshRejected, nil)
        var shaky = open
        shaky.issue = UsageFailure.network.message
        expectEqual(policy.obstacle(for: shaky, at: now), nil)
    }
    /// The account just left is skipped for 300 seconds, including when it is the only one that looks ready.
    /// After the cooldown the same account can be chosen again.
    func testAccountJustLeftIsSkippedUntilTheCooldownEnds() {
        expectEqual(RelayPolicy.departureCooldown, 300)
        var active = Account(label: "Fixture A", kind: .oauth)
        active.usage = snapshot(0.5, 40)
        var left = Account(label: "Fixture B", kind: .oauth)
        left.hotSwitchCapability = .verified
        left.usage = snapshot(80, 80)
        var other = Account(label: "Fixture C", kind: .oauth)
        other.hotSwitchCapability = .verified
        other.usage = snapshot(70, 70)
        let cooling = RelayPolicy(allowUnverifiedHotSwitch: true, leftRecently: left.id)
        expectEqual(cooling.obstacle(for: left, at: now), "刚刚离开")
        expectEqual(cooling.decide(active: active, candidates: [left, other], at: now), .select(other.id))
        guard case .pause = cooling.decide(active: active, candidates: [left], at: now) else { fatalError("Expected pause") }
        expectEqual(RelayPolicy.coolingDown(left.id, since: now.addingTimeInterval(-299), at: now), Optional(left.id))
        expectEqual(RelayPolicy.coolingDown(left.id, since: now.addingTimeInterval(-300), at: now), nil)
        expectEqual(RelayPolicy.coolingDown(left.id, since: now.addingTimeInterval(10), at: now), nil)
        let cooled = RelayPolicy(allowUnverifiedHotSwitch: true, leftRecently: RelayPolicy.coolingDown(left.id, since: now.addingTimeInterval(-300), at: now))
        expectEqual(cooled.decide(active: active, candidates: [left], at: now), .select(left.id))
    }
    /// Off by default, so a healthy account is not handed off early. On, it picks the earlier weekly reset
    /// when both windows are above the threshold, and ignores an unknown reset. At the threshold the user's
    /// order wins, and nobody under the threshold is chosen just because their window resets sooner.
    func testSoonerWeeklyResetIsOptionalAndDoesNotReplaceOrdinaryRelay() {
        let day = 86_400.0
        let active = placed("Fixture A", five: 40, week: 50, weekResetsIn: 3 * day)
        let sooner = placed("Fixture B", five: 30, week: 30, weekResetsIn: day)
        let later = placed("Fixture C", five: 90, week: 90, weekResetsIn: 6 * day)
        let unknown = placed("Fixture D", five: 90, week: 90, weekResetsIn: nil)
        let tied = placed("Fixture I", five: 80, week: 80, weekResetsIn: 3 * day)
        expectEqual(RelayPolicy().decide(active: active, candidates: [later, sooner], at: now), .wait)
        let on = RelayPolicy(soonerWeekly: true)
        expectEqual(on.decide(active: active, candidates: [later, unknown, sooner], at: now), .select(sooner.id))
        expectEqual(on.decide(active: active, candidates: [unknown], at: now), .wait)
        expectEqual(on.decide(active: active, candidates: [later], at: now), .wait)
        expectEqual(on.decide(active: active, candidates: [tied], at: now), .wait)
        let thin = placed("Fixture E", five: 0.4, week: 80, weekResetsIn: day)
        expectEqual(on.decide(active: active, candidates: [thin], at: now), .wait)
        let spent = placed("Fixture A", five: 0.4, week: 40, weekResetsIn: 6 * day)
        let first = placed("Fixture F", five: 50, week: 50, weekResetsIn: 4 * day)
        let thinnerSooner = placed("Fixture G", five: 15, week: 15, weekResetsIn: day)
        expectEqual(on.decide(active: spent, candidates: [first, thinnerSooner], at: now), .select(first.id))
        let alsoSpent = placed("Fixture H", five: 0.2, week: 0.2, weekResetsIn: day)
        guard case .pause = on.decide(active: spent, candidates: [alsoSpent], at: now) else { fatalError("Expected pause") }
    }
    /// Sorting goes by the day the 7-day window resets, sooner first, and within a day by what is left, more first.
    /// The 5-hour window does not move anyone. Unknown, reset-since-read and disabled accounts trail in the user's order.
    func testAutoSortOrdersByWeeklyResetDayThenWhatIsLeft() {
        let hour: TimeInterval = 3600, day: TimeInterval = 86400
        expectEqual(RelayOrder.day(until: now.addingTimeInterval(hour), at: now), 0)
        expectEqual(RelayOrder.day(until: now.addingTimeInterval(23 * hour), at: now), 0)
        expectEqual(RelayOrder.day(until: now.addingTimeInterval(30 * hour), at: now), 1)
        expectEqual(RelayOrder.day(until: now.addingTimeInterval(6.9 * day), at: now), 7)
        let weekEighty = placed("Fixture A", five: 100, week: 80, weekResetsIn: 6.9 * day)
        let weekFull = placed("Fixture B", five: 5, week: 100, weekResetsIn: 6.8 * day)
        let dayThirty = placed("Fixture C", five: 100, week: 30, weekResetsIn: day + hour)
        let dayEighty = placed("Fixture D", five: 40, week: 80, weekResetsIn: day + 2 * hour)
        let hourSoon = placed("Fixture E", five: 100, week: 10, weekResetsIn: hour)
        var unstarted = placed("Fixture F", five: 100, week: 100, weekResetsIn: nil)
        unstarted.usage?.sevenDay = UsageWindow(used: 0)
        var unread = Account(label: "Fixture G", kind: .oauth)
        unread.usage = nil
        let resetSinceRead = placed("Fixture H", five: 100, week: 20, weekResetsIn: -hour)
        var disabled = placed("Fixture I", five: 100, week: 100, weekResetsIn: hour)
        disabled.enabled = false
        let input = [disabled, unread, weekEighty, weekFull, resetSinceRead, dayThirty, unstarted, dayEighty, hourSoon]
        let order = RelayOrder.sorted(input, at: now).map(\.label)
        expectEqual(order, ["Fixture E", "Fixture D", "Fixture C", "Fixture B", "Fixture F", "Fixture A", "Fixture G", "Fixture H", "Fixture I"])
        // Identical keys keep the order they came in, so sorting never shuffles accounts it cannot tell apart.
        let twin = placed("Fixture J", five: 100, week: 80, weekResetsIn: 6.9 * day)
        expectEqual(RelayOrder.sorted([twin, weekEighty], at: now).map(\.label), ["Fixture J", "Fixture A"])
        expectFalse(Preferences().autoSort == true)
    }
    /// The hand-offs of 2026-10-22 in miniature. The account in use leaves ahead of the threshold with 13% left, and the
    /// relay order puts accounts with 10% and 14% left first. The baton goes to the emptiest account, the relay order
    /// deciding only between accounts within ten points of each other, and never to one closer to the limit than the
    /// account being left.
    func testHandOffGoesToTheEmptiestAccount() {
        let day: TimeInterval = 86400
        let active = placed("Fixture A", five: 13, week: 40, weekResetsIn: 3 * day)
        let nearlyFull = placed("Fixture B", five: 10, week: 89, weekResetsIn: day)
        let thin = placed("Fixture C", five: 14, week: 60, weekResetsIn: day)
        let used = placed("Fixture D", five: 93, week: 25, weekResetsIn: 2 * day)
        var untouched = placed("Fixture E", five: 100, week: 70, weekResetsIn: 5 * day)
        untouched.usage?.fiveHour = UsageWindow(used: 0)
        let live = RelayPolicy(threshold: 5, allowUnverifiedHotSwitch: true)
        let order = [nearlyFull, thin, used, untouched]
        expectEqual(live.handOffOrder(order, leaving: active, at: now).map(\.label), ["Fixture D", "Fixture E", "Fixture C"])
        expectEqual(live.decide(active: active, candidates: order, at: now, ahead: true), .select(used.id))
        // Ahead of the threshold, an account with less room than the one in use is no way out.
        guard case .pause = live.decide(active: active, candidates: [nearlyFull], at: now, ahead: true) else { fatalError("Expected pause") }
        // At the threshold anything above it will do, emptiest first; more than ten points apart, room beats order.
        let spent = placed("Fixture A", five: 4, week: 40, weekResetsIn: 3 * day)
        expectEqual(live.decide(active: spent, candidates: [nearlyFull, thin], at: now), .select(thin.id))
        expectEqual(live.decide(active: spent, candidates: [nearlyFull], at: now), .select(nearlyFull.id))
        expectEqual(live.handOffOrder([thin, untouched], leaving: spent, at: now).map(\.label), ["Fixture E", "Fixture C"])
        // A weekly window as low as the account in use keeps an account out too, whatever its 5-hour window.
        let weekSpent = placed("Fixture F", five: 100, week: 4, weekResetsIn: day)
        expectEqual(live.handOffOrder([weekSpent, thin], leaving: spent, at: now).map(\.label), ["Fixture C"])
        // Still above the threshold and not ahead of it: nothing moves.
        let healthy = placed("Fixture G", five: 40, week: 60, weekResetsIn: 3 * day)
        expectEqual(live.decide(active: healthy, candidates: [untouched], at: now), .wait)
    }
    /// What Lilt last read of an idle account sets the order a hand-off reads accounts in, however old the reading. The
    /// account taken must have been read in the last two minutes. A window that has reset since the reading counts as
    /// full for the order only, and an account still used up until its reset is left out, so it is not read before then.
    func testHandOffConfirmsTheAccountItTakes() {
        expectEqual(RelayPolicy.confirmLifetime, 120)
        let active = placed("Fixture A", five: 3, week: 40, weekResetsIn: 86400)
        var old = placed("Fixture B", five: 100, week: 80, weekResetsIn: 86400); old.usage?.sampledAt = now.addingTimeInterval(-3600)
        var recent = placed("Fixture C", five: 60, week: 80, weekResetsIn: 86400); recent.usage?.sampledAt = now.addingTimeInterval(-119)
        let live = RelayPolicy(threshold: 5, allowUnverifiedHotSwitch: true)
        expectEqual(live.handOffOrder([recent, old], leaving: active, at: now).map(\.label), ["Fixture B", "Fixture C"])
        expectEqual(live.obstacle(for: old, at: now), "额度未确认")
        // Until Fixture B is read, the hand-off can only go to the account read recently.
        expectEqual(live.decide(active: active, candidates: [recent, old], at: now), .select(recent.id))
        old.usage?.sampledAt = now
        expectEqual(live.decide(active: active, candidates: [recent, old], at: now), .select(old.id))
        recent.usage?.sampledAt = now.addingTimeInterval(-121)
        guard case .pause = live.decide(active: active, candidates: [recent], at: now) else { fatalError("Expected pause") }
        var spent = Account(label: "Fixture D", kind: .oauth); spent.hotSwitchCapability = .verified
        spent.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now.addingTimeInterval(1800)), sevenDay: UsageWindow(used: 10), sampledAt: now.addingTimeInterval(-3600))
        expectEqual(live.handOffOrder([spent], leaving: active, at: now).count, 0)
        expectEqual(live.obstacle(for: spent, at: now), "额度不足或不完整")
        spent.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now.addingTimeInterval(-60)), sevenDay: UsageWindow(used: 10), sampledAt: now.addingTimeInterval(-30))
        expectEqual(live.handOffOrder([recent, spent], leaving: active, at: now).map(\.label), ["Fixture D", "Fixture C"])
        expectEqual(live.obstacle(for: spent, at: now), "额度不足或不完整")
        // Never read: after every account with a reading, in relay order. Accounts that can never take over are left out.
        var unread = Account(label: "Fixture E", kind: .oauth); unread.hotSwitchCapability = .verified
        var rejected = old; rejected.refreshRejected = true
        var off = old; off.enabled = false
        var unreadable = old; unreadable.usageCapability = .unavailable
        expectEqual(live.handOffOrder([unread, rejected, off, unreadable, recent], leaving: active, at: now).map(\.label), ["Fixture C", "Fixture E"])
        expectEqual(live.obstacle(for: unread, at: now), "额度未知")
    }
    /// The hand-off reads the account in front, and when the reading shows that someone spent it meanwhile, moves on to
    /// the next. Readings Lilt had of B and C were minutes old and promised plenty; in truth B had 10% left and C 14%,
    /// as on 2026-10-22. The old rule took B on its ten-minute-old reading. Now B and C are read and passed over,
    /// D is read and taken, and E, last read an hour ago, is never asked.
    func testHandOffReadsTheTargetAndMovesOnWhenItWasSpent() {
        let day: TimeInterval = 86400
        let active = placed("Fixture A", five: 13, week: 40, weekResetsIn: 3 * day)
        func stale(_ account: Account, age: TimeInterval) -> Account { var copy = account; copy.usage?.sampledAt = now.addingTimeInterval(-age); return copy }
        let truth = [placed("Fixture B", five: 10, week: 89, weekResetsIn: day), placed("Fixture C", five: 14, week: 60, weekResetsIn: day),
                     placed("Fixture D", five: 96, week: 25, weekResetsIn: 2 * day), placed("Fixture E", five: 93, week: 70, weekResetsIn: 5 * day)]
        var known = [stale(placed("Fixture B", five: 100, week: 90, weekResetsIn: day), age: 540), stale(placed("Fixture C", five: 98, week: 61, weekResetsIn: day), age: 300),
                     stale(truth[2], age: 3600), stale(truth[3], age: 3600)]
        for index in known.indices { known[index].id = truth[index].id }
        let live = RelayPolicy(threshold: 5, allowUnverifiedHotSwitch: true)
        var asked = Set<UUID>()
        while asked.count < RelayPolicy.handOffReads, let next = live.nextRead(known, leaving: active, asked: asked, readable: { _ in true }, at: now) {
            asked.insert(next.id)
            let index = known.firstIndex { $0.id == next.id }!
            known[index] = truth[index]
        }
        expectEqual(known.filter { asked.contains($0.id) }.map(\.label), ["Fixture B", "Fixture C", "Fixture D"])
        expectEqual(live.decide(active: active, candidates: known, at: now, ahead: true), .select(truth[2].id))
        // An account whose read failed is not asked again in the same hand-off, and one that cannot be asked is skipped.
        expectEqual(live.nextRead(known, leaving: active, asked: [truth[2].id], readable: { _ in true }, at: now), nil)
        let fresh = known
        known[2].usage?.sampledAt = now.addingTimeInterval(-3600)
        expectEqual(live.nextRead(known, leaving: active, asked: [truth[2].id], readable: { _ in true }, at: now)?.label, "Fixture E")
        expectEqual(live.nextRead(known, leaving: active, asked: [], readable: { $0 != truth[2].id }, at: now)?.label, "Fixture E")
        expectEqual(live.nextRead(fresh, leaving: active, asked: [], readable: { _ in false }, at: now), nil)
    }
    /// Each window has its own threshold. Files written before keep one figure for both, and a literal still sets both.
    func testEachWindowHasItsOwnThreshold() throws {
        expectEqual(Thresholds(5), Thresholds(fiveHour: 5, sevenDay: 5)); expectEqual(Thresholds(fiveHour: -1, sevenDay: 120), Thresholds(fiveHour: 0, sevenDay: 100))
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"threshold":5,"scopeEnabled":true,"shortcutKey":37,"shortcutModifiers":2304}"#.utf8))
        expectEqual(old.thresholds, Thresholds(5))
        var apart = old; apart.threshold = 15; apart.weeklyThreshold = 5
        expectEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(apart)).thresholds, Thresholds(fiveHour: 15, sevenDay: 5))
        let t = Thresholds(fiveHour: 15, sevenDay: 5)
        expect(snapshot(14, 50).exhausted(threshold: t, at: now)); expect(snapshot(60, 4).exhausted(threshold: t, at: now))
        expectFalse(snapshot(16, 6).exhausted(threshold: t, at: now)); expect(snapshot(16, 6).available(threshold: t, at: now))
        // A hand-off measures each window against its own figure: 14% left on the 5-hour window is out at 15%, while 6%
        // left on the weekly one is still above 5%.
        let live = RelayPolicy(threshold: t, allowUnverifiedHotSwitch: true)
        var active = Account(label: "Fixture A", kind: .oauth); active.usage = snapshot(15, 40)
        var thin = Account(label: "Fixture B", kind: .oauth); thin.usage = snapshot(14, 90)
        var weekly = Account(label: "Fixture C", kind: .oauth); weekly.usage = snapshot(100, 6)
        expectEqual(live.decide(active: active, candidates: [thin, weekly], at: now), .select(weekly.id))
        expectEqual(live.obstacle(for: thin, at: now), "额度不足或不完整")
        // Ahead of the threshold, the account taken must be further above its thresholds than the one left: 20% on the
        // 5-hour window is 5 points above 15%, so an account whose weekly window is 1 point above 5% does not qualify.
        active.usage = snapshot(20, 40)
        guard case .pause = live.decide(active: active, candidates: [weekly], at: now, ahead: true) else { fatalError("Expected pause") }
        weekly.usage = snapshot(100, 30)
        expectEqual(live.decide(active: active, candidates: [weekly], at: now, ahead: true), .select(weekly.id))
        // The early hand-off counts toward each window's own threshold: four points a minute from 20% reaches 15%.
        let reading = { (left: Double, ago: TimeInterval) in
            UsageSnapshot(fiveHour: UsageWindow(used: 100 - left, resetsAt: self.now.addingTimeInterval(3600)), sevenDay: UsageWindow(used: 60, resetsAt: self.now.addingTimeInterval(86400)), sampledAt: self.now.addingTimeInterval(-ago))
        }
        expect(UsagePace.nearing(reading(19, 0), after: [reading(23, 60)], threshold: t, at: now, lifetime: 300))
        expectFalse(UsagePace.nearing(reading(19, 0), after: [reading(23, 60)], threshold: 5, at: now, lifetime: 300))
        // Retry after a pause waits for the window that is at its own threshold.
        var waiting = Account(label: "Fixture D", kind: .oauth)
        waiting.usage = UsageSnapshot(fiveHour: UsageWindow(used: 86, resetsAt: now.addingTimeInterval(900)), sevenDay: UsageWindow(used: 50, resetsAt: now.addingTimeInterval(86400)), sampledAt: now)
        expectEqual(live.nextReset(of: [waiting], at: now), now.addingTimeInterval(900))
        expectEqual(RelayPolicy(threshold: 5).nextReset(of: [waiting], at: now), nil)
    }
    /// After a pause the next try is timed to the first account that gets its quota back.
    func testRetryWaitsForTheFirstReset() {
        let live = RelayPolicy(threshold: 5, allowUnverifiedHotSwitch: true)
        var soon = Account(label: "Fixture B", kind: .oauth)
        soon.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now.addingTimeInterval(600)), sevenDay: UsageWindow(used: 20, resetsAt: now.addingTimeInterval(86400)), sampledAt: now)
        var both = Account(label: "Fixture C", kind: .oauth)
        both.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now.addingTimeInterval(300)), sevenDay: UsageWindow(used: 99, resetsAt: now.addingTimeInterval(7200)), sampledAt: now)
        var spare = Account(label: "Fixture D", kind: .oauth); spare.usage = snapshot(50, 50)
        // Fixture C is out until its weekly window resets as well, so Fixture B gets its quota back first.
        expectEqual(live.nextReset(of: [both, soon, spare], at: now), now.addingTimeInterval(600))
        soon.enabled = false
        expectEqual(live.nextReset(of: [both, soon, spare], at: now), now.addingTimeInterval(7200))
        expectEqual(live.nextReset(of: [spare], at: now), nil)
    }
    /// A hand-off starts ahead of the threshold when the pace of spending would carry the account past it within the
    /// reaction time, as early as that pace requires, and only on readings of the same window far enough apart.
    func testPaceStartsTheHandOffAhead() {
        func reading(_ remaining: Double, ago: TimeInterval, resetsIn: TimeInterval = 3600) -> UsageSnapshot {
            UsageSnapshot(fiveHour: UsageWindow(used: 100 - remaining, resetsAt: now.addingTimeInterval(resetsIn)),
                          sevenDay: UsageWindow(used: 30, resetsAt: now.addingTimeInterval(86400)), sampledAt: now.addingTimeInterval(-ago), source: UsageParser.statusLineSource)
        }
        let latest = reading(8, ago: 0)
        // Four points in the last minute: four more in the next one reaches 5%.
        expect(UsagePace.nearing(latest, after: [reading(12, ago: 60)], threshold: 5, at: now, lifetime: 300))
        // One point in ten minutes is no reason to leave early.
        expectFalse(UsagePace.nearing(latest, after: [reading(9, ago: 590)], threshold: 5, at: now, lifetime: 300))
        // Readings seconds apart do not measure a pace, and neither does one from before the window reset.
        expectFalse(UsagePace.nearing(latest, after: [reading(9, ago: 10)], threshold: 5, at: now, lifetime: 300))
        expectFalse(UsagePace.nearing(latest, after: [reading(40, ago: 60, resetsIn: 3600 - 18000)], threshold: 5, at: now, lifetime: 300))
        expectFalse(UsagePace.nearing(latest, after: [], threshold: 5, at: now, lifetime: 300))
        // There is no fixed cap: 44 points in the last minute is 44 more in the next, so 16% left is already late.
        // Until 0.2.5 the hand-off started at most ten points early and came too late for bursts like this.
        expect(UsagePace.nearing(reading(16, ago: 0), after: [reading(60, ago: 60)], threshold: 5, at: now, lifetime: 300))
        expect(UsagePace.projectedMargin(reading(16, ago: 0), after: [reading(60, ago: 60)], at: now, lifetime: 300).fiveHour > 40)
        // A measured hand-off that took longer widens the margin in proportion.
        let slow = UsagePace.projectedMargin(latest, after: [reading(12, ago: 60)], at: now, lifetime: 300, reactionTime: 120)
        expectEqual(slow.fiveHour.rounded(), 8)
        // A point rounded up between two recent readings is no burst.
        expectFalse(UsagePace.nearing(latest, after: [reading(9, ago: 590), reading(9, ago: 40)], threshold: 5, at: now, lifetime: 300))
        // A burst after a quiet stretch counts at its own pace: three points in the last 40 seconds, whatever the
        // ten-minute average says. Sessions started all at once on an idle account spend like this.
        expect(UsagePace.nearing(latest, after: [reading(9, ago: 590), reading(11, ago: 40)], threshold: 5, at: now, lifetime: 300))
        // A reading too old to act on is not acted on early either.
        expectFalse(UsagePace.nearing(reading(8, ago: 301), after: [reading(12, ago: 361)], threshold: 5, at: now, lifetime: 300))
        // The policy takes the hand-off as due.
        var active = Account(label: "Fixture A", kind: .oauth); active.usage = latest
        var ready = Account(label: "Fixture B", kind: .oauth); ready.usage = snapshot(50, 50)
        let live = RelayPolicy(threshold: 5, allowUnverifiedHotSwitch: true)
        expectEqual(live.decide(active: active, candidates: [ready], at: now), .wait)
        expectEqual(live.decide(active: active, candidates: [ready], at: now, ahead: true), .select(ready.id))
    }
    /// Versions compare numerically and ignore trailing zeros; tags with a suffix or anything else are not versions.
    func testUpdateVersionsCompareNumerically() {
        let v = { (text: String) in AppVersion(text)! }
        expect(v("0.1.10") > v("0.1.9")); expect(v("v0.2") > v("0.1.99")); expect(v("1.0") == v("1.0.0"))
        expectFalse(v("0.1.2") > v("0.1.2")); expectEqual(v("v0.1.2").description, "0.1.2")
        for bad in ["", "v", "0.1.2-beta", "0.1.x", "0..1", "1.2.3.4.5", "٠.١", "1234567.0", "开发版"] { expect(AppVersion(bad) == nil) }
        expect(AppVersion(" 0.1 ") != nil)
    }
    /// Only a published release newer than the running one, with an image named for its own version, served from
    /// GitHub over HTTPS and within the size limit, is offered. Pre-releases count; drafts do not.
    func testUpdateFeedOffersOnlyAMatchingNewerRelease() throws {
        func release(_ tag: String, draft: Bool = false, prerelease: Bool = true, asset: String? = nil, link: String? = nil,
                     size: Int = 2_500_000, digest: String? = "sha256:" + String(repeating: "ab", count: 32), state: String = "uploaded") -> [String: Any] {
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let name = asset ?? "Lilt-\(version).dmg"
            var file: [String: Any] = ["name": name, "size": size, "state": state,
                                       "browser_download_url": link ?? "https://github.com/fixture-owner/Lilt/releases/download/\(tag)/\(name)"]
            if let digest { file["digest"] = digest }
            return ["tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": "https://github.com/fixture-owner/Lilt/releases/tag/\(tag)",
                    "body": "fixture notes", "assets": [file, ["name": "Source.zip", "size": 10, "browser_download_url": "https://github.com/fixture.zip"]]]
        }
        func newest(_ releases: [[String: Any]], after current: String = "0.1.2") throws -> UpdateRelease? {
            try UpdateFeed.newest(in: JSONSerialization.data(withJSONObject: releases), after: AppVersion(current)!)
        }
        let found = try newest([release("v0.1.2"), release("v0.1.10"), release("v0.1.3")])
        expectEqual(found?.version, AppVersion("0.1.10")); expectEqual(found?.sha256, String(repeating: "ab", count: 32))
        expectEqual(found?.asset.lastPathComponent, "Lilt-0.1.10.dmg"); expectEqual(found?.notes, "fixture notes")
        let nothingNewer = try newest([release("v0.1.2"), release("v0.1.1")]), sameVersion = try newest([release("v0.1.3")], after: "0.1.3")
        expect(nothingNewer == nil); expect(sameVersion == nil)
        let stable = try newest([release("v0.1.3", prerelease: false)])
        expectEqual(stable?.version, AppVersion("0.1.3"))
        // Each of these leaves the newer release out, so the older one is what remains.
        let older = release("v0.1.3")
        for rejected in [release("v0.2.0", draft: true), release("v0.2.0-beta"), release("v0.2.0", asset: "Lilt-0.1.9.dmg"),
                         release("v0.2.0", asset: "Lilt-0.2.0.zip"), release("v0.2.0", link: "http://github.com/fixture/Lilt-0.2.0.dmg"),
                         release("v0.2.0", link: "https://github.com.example.invalid/Lilt-0.2.0.dmg"), release("v0.2.0", size: 0),
                         release("v0.2.0", size: UpdateFeed.maximumSize + 1), release("v0.2.0", digest: "md5:abc"),
                         release("v0.2.0", digest: "sha256:xyz"), release("v0.2.0", state: "starter")] {
            let remaining = try newest([rejected, older])
            expectEqual(remaining?.version, AppVersion("0.1.3"))
        }
        // A release without a digest is still offered; the size check and the bundle checks remain.
        let undigested = try newest([release("v0.1.3", digest: nil)])
        expect(undigested != nil); expectEqual(undigested?.sha256, nil)
        expectThrows(try UpdateFeed.newest(in: Data("{\"message\":\"Not Found\"}".utf8), after: AppVersion("0.1.2")!))
        expectThrows(try UpdateFeed.newest(in: Data("not json".utf8), after: AppVersion("0.1.2")!))
    }
    /// Downloads and redirects stay on GitHub over HTTPS; the swap needs a real app bundle; the unpacked app must be
    /// exactly the release; automatic checks wait their interval but survive a clock set backwards.
    func testUpdateInstallBoundaries() {
        for good in ["https://github.com/a/b", "https://api.github.com/repos", "https://release-assets.githubusercontent.com/x", "https://GitHub.com/a"] {
            expect(UpdateFeed.allowsDownload(from: URL(string: good)!))
        }
        for bad in ["http://github.com/a", "https://evilgithub.com/a", "https://github.com.example.invalid/a", "https://githubusercontent.com.example.invalid/a",
                    "https://user@github.com/a", "https://github.com:8443/a", "file:///tmp/Lilt.dmg", "https://example.invalid/Lilt.dmg"] {
            expectFalse(UpdateFeed.allowsDownload(from: URL(string: bad)!))
        }
        expect(UpdateFeed.installBlocker(bundlePath: "/Applications/Lilt.app") == nil)
        expect(UpdateFeed.installBlocker(bundlePath: "/Users/fixture/Applications/Lilt.app") == nil)
        expect(UpdateFeed.installBlocker(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/Lilt.app") != nil)
        expect(UpdateFeed.installBlocker(bundlePath: "/Users/fixture/Lilt/.build/debug") != nil)
        let info: [String: Any] = ["CFBundleIdentifier": "app.lilt.desktop", "CFBundleExecutable": "Lilt", "CFBundleShortVersionString": "0.1.3"]
        expect(UpdateFeed.matches(info: info, version: AppVersion("0.1.3")!))
        expectFalse(UpdateFeed.matches(info: info, version: AppVersion("0.1.4")!))
        var other = info; other["CFBundleIdentifier"] = "app.example.invalid"
        expectFalse(UpdateFeed.matches(info: other, version: AppVersion("0.1.3")!))
        other = info; other["CFBundleExecutable"] = "Other"
        expectFalse(UpdateFeed.matches(info: other, version: AppVersion("0.1.3")!))
        expectFalse(UpdateFeed.matches(info: [:], version: AppVersion("0.1.3")!))
        expectEqual(UpdateFeed.sha256(fromDigest: "sha256:" + String(repeating: "AB", count: 32)), String(repeating: "ab", count: 32))
        expect(UpdateFeed.sha256(fromDigest: "sha256:" + String(repeating: "a", count: 63)) == nil)
        expect(UpdateFeed.due(lastCheck: nil, now: now))
        expectFalse(UpdateFeed.due(lastCheck: now.addingTimeInterval(-3600), now: now))
        expect(UpdateFeed.due(lastCheck: now.addingTimeInterval(-UpdateFeed.interval), now: now))
        expect(UpdateFeed.due(lastCheck: now.addingTimeInterval(3600), now: now))
        expect(Preferences().autoUpdateCheck == nil)
    }
    private func placed(_ label: String, five: Double, week: Double, weekResetsIn: TimeInterval?) -> Account {
        var account = Account(label: label, kind: .oauth)
        account.hotSwitchCapability = .verified
        account.usage = UsageSnapshot(
            fiveHour: UsageWindow(used: 100 - five, resetsAt: now.addingTimeInterval(3 * 3600)),
            sevenDay: UsageWindow(used: 100 - week, resetsAt: weekResetsIn.map { now.addingTimeInterval($0) }),
            sampledAt: now
        )
        return account
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
        suite.testRelayKeepsATriggerWhileOtherAccountsAreRead()
        suite.testSecurityPrintsNonASCIIPasswordsAsHex()
        try suite.testPreferencesWrittenBeforeAutoRelayStillLoad()
        suite.testRenewalKeepsTheRestOfTheDocument()
        suite.testReadBackOnlyAdoptsWhatIsProvablyTheSameLogin()
        suite.testStatusLineReadingsAreParsedAndMatchedToTheirAccount()
        suite.testDuplicateEventClaimedOnce()
        suite.testRetryAfterAndAuthentication()
        suite.testUsagePollingKeepsAlternatesAndResetsMoving()
        try suite.testParserRejectsMalformedAndBooleanUsage()
        suite.testRenewalLeadIsTwiceTheCLIBuffer()
        try suite.testRejectedRefreshLeavesAutomaticRelayUntilReauthorized()
        suite.testAccountJustLeftIsSkippedUntilTheCooldownEnds()
        suite.testSoonerWeeklyResetIsOptionalAndDoesNotReplaceOrdinaryRelay()
        suite.testAutoSortOrdersByWeeklyResetDayThenWhatIsLeft()
        suite.testHandOffGoesToTheEmptiestAccount()
        suite.testHandOffConfirmsTheAccountItTakes()
        suite.testHandOffReadsTheTargetAndMovesOnWhenItWasSpent()
        suite.testRetryWaitsForTheFirstReset()
        try suite.testEachWindowHasItsOwnThreshold()
        suite.testPaceStartsTheHandOffAhead()
        suite.testUpdateVersionsCompareNumerically()
        try suite.testUpdateFeedOffersOnlyAMatchingNewerRelease()
        suite.testUpdateInstallBoundaries()
        try storageChecks()
        let concurrency = ConcurrencyChecks()
        concurrency.testBurstChannel()
        concurrency.testCandidateMarginCoversPaceAndSwitchCost()
        concurrency.testPreparationTiming()
        concurrency.testRetryAtTheEarliestApplicableTime()
        try concurrency.testSpoolKeepsEveryEventAndTheHighWaterMark()
        concurrency.testFoldRules()
        try concurrency.testProjectRules()
        try concurrency.testImportPlanAndTransaction()
        try credentialTransferChecks()
        print("PASS: 39 rule suites + secure storage checks — boundaries, freshness, last-known display, reset, candidates, live relay, held trigger, keychain hex, stored preferences, token renewal, read-back, status line readings, deduplication, backoff, parsing, renewal lead, refresh quarantine, departure cooldown, sooner weekly, automatic order, emptiest account first, the account taken read first, moving on from a spent one, retry at the first reset, a threshold per window, pace ahead of the threshold, update versions, update feed, update boundaries, burst channel, candidate margin and switch cost, preparation timing, retry at the earliest applicable time, per-event spool and high-water mark, fold rules, project rules, import plan and transaction, encrypted archive")
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
