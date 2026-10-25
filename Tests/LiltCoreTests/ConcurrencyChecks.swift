import Foundation
import LiltCore

/// Rules for four or five projects working at once: events that arrive together, bursts, the margin a hand-off
/// needs, when to read ahead and when to try again, plus project bindings and the account import. Fixture data only.
final class ConcurrencyChecks: Sendable {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset5 = Date(timeIntervalSince1970: 1_800_000_000 + 3600)
    let reset7 = Date(timeIntervalSince1970: 1_800_000_000 + 86400)

    func reading(_ remaining: Double, ago: TimeInterval, weekly: Double = 70) -> UsageSnapshot {
        UsageSnapshot(fiveHour: UsageWindow(used: 100 - remaining, resetsAt: reset5),
                      sevenDay: UsageWindow(used: 100 - weekly, resetsAt: reset7),
                      sampledAt: now.addingTimeInterval(-ago), source: UsageParser.statusLineSource)
    }

    /// A burst shows within seconds, but only from three readings with two real drops: one jump is not a pace.
    func testBurstChannel() {
        let latest = reading(20, ago: 0)
        expect(UsagePace.nearing(latest, after: [reading(23, ago: 8), reading(22, ago: 4)], threshold: 5, at: now, lifetime: 300))
        expectEqual(UsagePace.projectedMargin(latest, after: [reading(23, ago: 8), reading(22, ago: 4)], at: now, lifetime: 300).fiveHour, 22.5)
        expectFalse(UsagePace.nearing(latest, after: [reading(23, ago: 8)], threshold: 5, at: now, lifetime: 300))
        expectFalse(UsagePace.nearing(latest, after: [reading(23, ago: 8), reading(23, ago: 4)], threshold: 5, at: now, lifetime: 300))
        // Readings more than ten seconds back are the long channel's, which needs 30 seconds.
        expectFalse(UsagePace.nearing(latest, after: [reading(26, ago: 20), reading(23, ago: 15)], threshold: 5, at: now, lifetime: 300))
    }

    /// An account taking over must cover the pace during a hand-off and what the last switch cost, and never less
    /// than two points; an account just above the threshold is not taken.
    func testCandidateMarginCoversPaceAndSwitchCost() {
        expectEqual(UsagePace.candidateMargin(pace: 0, allowance: 0), Thresholds(2))
        expectEqual(UsagePace.candidateMargin(pace: Thresholds(fiveHour: 6, sevenDay: 0.5), allowance: Thresholds(fiveHour: 3, sevenDay: 0)),
                    Thresholds(fiveHour: 9, sevenDay: 2))
        var thin = Account(label: "Fixture thin", kind: .oauth); thin.usage = reading(2.5, ago: 0)
        var roomy = Account(label: "Fixture roomy", kind: .oauth); roomy.usage = reading(10, ago: 0)
        let policy = RelayPolicy(threshold: 1, allowUnverifiedHotSwitch: true, requiredMargin: UsagePace.candidateMargin(pace: 0, allowance: 0))
        expectEqual(policy.obstacle(for: thin, at: now), "预测余量不足")
        expectEqual(policy.obstacle(for: roomy, at: now), nil)
        var active = Account(label: "Fixture active", kind: .oauth); active.usage = reading(1, ago: 0)
        expectEqual(policy.decide(active: active, candidates: [thin, roomy], at: now), .select(roomy.id))
        expectEqual(policy.handOffOrder([thin, roomy], leaving: active, at: now).map(\.id), [roomy.id])
        // What the first reading after a switch shows less than the one the account was chosen on.
        expectEqual(UsagePace.switchAllowance(confirmed: reading(30, ago: 60), first: reading(26, ago: 0)).fiveHour, 4)
        expectEqual(UsagePace.switchAllowance(confirmed: reading(60, ago: 60), first: reading(20, ago: 0)).fiveHour, 10)
        let otherWindow = UsageSnapshot(fiveHour: UsageWindow(used: 90, resetsAt: reset5.addingTimeInterval(7200)), sampledAt: now)
        expectEqual(UsagePace.switchAllowance(confirmed: reading(30, ago: 60), first: otherWindow).fiveHour, 0)
        expectEqual(UsagePace.switchAllowance(confirmed: reading(20, ago: 60), first: reading(25, ago: 0)).fiveHour, 0)
        // The time a hand-off took sets the reaction budget, within one to five minutes.
        expectEqual(UsagePace.reactionTime(measured: nil), 60)
        expectEqual(UsagePace.reactionTime(measured: 20), 60)
        expectEqual(UsagePace.reactionTime(measured: 90), 90)
        expectEqual(UsagePace.reactionTime(measured: 1000), 300)
        expectEqual(UsagePace.reactionTime(measured: .infinity), 60)
    }

    /// Candidates are read ahead so that one is still confirmed when the hand-off comes, and an idle account near its
    /// threshold does not have them read every few seconds.
    func testPreparationTiming() {
        let latest = reading(20, ago: 0)
        let seconds = UsagePace.secondsToThreshold(latest, after: [reading(26, ago: 60)], threshold: 5, at: now, lifetime: 300)
        expectEqual(seconds.map { $0.rounded() }, 150)
        expect(UsagePace.secondsToThreshold(latest, after: [], threshold: 5, at: now, lifetime: 300) == nil)
        expect(UsagePace.secondsToThreshold(latest, after: [reading(20, ago: 60)], threshold: 5, at: now, lifetime: 300) == nil)
        expectFalse(RelayPolicy.preparationRead(age: 0, secondsToThreshold: 150, nearThreshold: true))
        expect(RelayPolicy.preparationRead(age: 30, secondsToThreshold: 100, nearThreshold: true))
        expectFalse(RelayPolicy.preparationRead(age: 10, secondsToThreshold: 100, nearThreshold: true))
        expect(RelayPolicy.preparationRead(age: 301, secondsToThreshold: nil, nearThreshold: true))
        expectFalse(RelayPolicy.preparationRead(age: 120, secondsToThreshold: nil, nearThreshold: true))
        expectFalse(RelayPolicy.preparationRead(age: 3000, secondsToThreshold: nil, nearThreshold: false))
    }

    /// A paused hand-off looks again at the first moment any candidate may qualify, not after a fixed two minutes.
    func testRetryAtTheEarliestApplicableTime() {
        let policy = RelayPolicy(threshold: 1, allowUnverifiedHotSwitch: true)
        var spent = Account(label: "Fixture spent", kind: .oauth)
        spent.usage = UsageSnapshot(fiveHour: UsageWindow(used: 100, resetsAt: now.addingTimeInterval(600)),
                                    sevenDay: UsageWindow(used: 10, resetsAt: reset7), sampledAt: now)
        var stale = Account(label: "Fixture stale", kind: .oauth); stale.usage = reading(50, ago: 300)
        var waiting = Account(label: "Fixture backoff", kind: .oauth); waiting.usage = reading(50, ago: 300)
        var weekLong = spent; weekLong.id = UUID()
        weekLong.usage?.fiveHour?.resetsAt = now.addingTimeInterval(3 * 3600)
        var off = stale; off.id = UUID(); off.enabled = false
        let none: (UUID) -> Date? = { _ in nil }
        expectEqual(policy.retryAt([spent], at: now, ordinary: 15, backoffUntil: none, cooldownEnds: nil), now.addingTimeInterval(605))
        expectEqual(policy.retryAt([spent, stale], at: now, ordinary: 15, backoffUntil: none, cooldownEnds: nil), now.addingTimeInterval(15))
        let backoff: (UUID) -> Date? = { $0 == waiting.id ? self.now.addingTimeInterval(40) : nil }
        expectEqual(policy.retryAt([spent, waiting], at: now, ordinary: 15, backoffUntil: backoff, cooldownEnds: nil), now.addingTimeInterval(40))
        expectEqual(policy.retryAt([weekLong], at: now, ordinary: 15, backoffUntil: none, cooldownEnds: nil),
                    now.addingTimeInterval(RelayPolicy.maximumRetryWait))
        expectEqual(policy.retryAt([off], at: now, ordinary: 30, backoffUntil: none, cooldownEnds: nil), now.addingTimeInterval(30))
        expectEqual(policy.retryAt([stale], at: now, ordinary: 0, backoffUntil: none, cooldownEnds: nil), now.addingTimeInterval(5))
        let cooling = RelayPolicy(threshold: 1, allowUnverifiedHotSwitch: true, leftRecently: stale.id)
        expectEqual(cooling.retryAt([stale], at: now, ordinary: 15, backoffUntil: none, cooldownEnds: now.addingTimeInterval(200)),
                    now.addingTimeInterval(200))
    }

    /// Five sessions writing at once lose nothing, the highest figure survives, and overflow or damage says so.
    func testSpoolKeepsEveryEventAndTheHighWaterMark() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/spool-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = root.appendingPathComponent("live-usage-spool")
        let limits = { (used: Double) in Self.limits(used, five: self.reset5, seven: self.reset7) }
        let values: [Double] = [61, 74, 57, 73, 68]
        DispatchQueue.concurrentPerform(iterations: 5) { writer in
            for round in 0..<8 {
                let id = "fixture-\(writer)-\(round)"
                // Everyone reports in the same second; the order of values is mixed high, mid and low.
                let used = values[(writer + round) % values.count] + Double(round) / 10
                let record = try! LiveUsageSpool.record(id: id, scope: LiveUsageEvent.defaultScope, at: now,
                                                        limits: Self.limits(used, five: reset5, seven: reset7))
                try! LiveUsageSpool.write(record, id: id, at: now, to: spool)
            }
        }
        let batch = LiveUsageSpool.drain(spool, scope: LiveUsageEvent.defaultScope, at: now)
        expectEqual(batch.events.count, 40); expectFalse(batch.hasGaps)
        expectEqual(Set(batch.events.map(\.id)).count, 40)
        expectFalse(LiveUsageSpool.hasPending(spool))
        let known = UsageSnapshot(fiveHour: UsageWindow(used: 40, resetsAt: reset5), sevenDay: UsageWindow(used: 30, resetsAt: reset7),
                                  sampledAt: now.addingTimeInterval(-30))
        let folded = LiveUsageFold.readings(batch.events, scope: LiveUsageEvent.defaultScope, known: known, since: .distantPast, at: now)
        expectEqual(folded.count, 40)
        expectEqual(folded.last?.fiveHour?.used, 74.7)
        expect(zip(folded, folded.dropFirst()).allSatisfy { $0.fiveHour!.used <= $1.fiveHour!.used })

        // Overflow keeps the newest 512 and says that some went.
        for index in 0..<(LiveUsageSpool.maximumEvents + 20) {
            let id = String(format: "overflow-%04d", index)
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            let record = try LiveUsageSpool.record(id: id, scope: LiveUsageEvent.defaultScope, at: now.addingTimeInterval(Double(index)), limits: limits(50))
            try SecureFiles.write(record, to: spool.appendingPathComponent(LiveUsageSpool.fileName(id: id, at: now.addingTimeInterval(Double(index)))))
        }
        let overflow = LiveUsageSpool.drain(spool, scope: LiveUsageEvent.defaultScope, at: now)
        expect(overflow.hasGaps); expectEqual(overflow.events.count, LiveUsageSpool.maximumEvents)
        expectEqual(overflow.events.first?.id, "overflow-0020")

        // A damaged file, another scope's event and a duplicate: the first two are gaps, the duplicate is one event.
        try SecureFiles.write(Data("{not json".utf8), to: spool.appendingPathComponent("0000000001-1-broken.json"))
        let foreign = try LiveUsageSpool.record(id: "foreign", scope: LiveUsageEvent.projectScope(UUID()), at: now, limits: limits(99))
        try LiveUsageSpool.write(foreign, id: "foreign", at: now, to: spool)
        let twice = try LiveUsageSpool.record(id: "twice", scope: LiveUsageEvent.defaultScope, at: now, limits: limits(55))
        try SecureFiles.write(twice, to: spool.appendingPathComponent("0000000002-1-twice.json"))
        try SecureFiles.write(twice, to: spool.appendingPathComponent("0000000003-2-twice.json"))
        let mixed = LiveUsageSpool.drain(spool, scope: LiveUsageEvent.defaultScope, at: now)
        expect(mixed.hasGaps); expectEqual(mixed.events.map(\.id), ["twice"])
        expectFalse(LiveUsageSpool.drain(spool, scope: LiveUsageEvent.defaultScope, at: now).hasGaps)

        // Someone else holding the lock delays the batch; it does not lose it.
        let held = try LiveUsageSpool.record(id: "held", scope: LiveUsageEvent.defaultScope, at: now, limits: limits(52))
        try LiveUsageSpool.write(held, id: "held", at: now, to: spool)
        try FileManager.default.createDirectory(at: spool.appendingPathComponent(LiveUsageSpool.lockName), withIntermediateDirectories: false)
        let blocked = LiveUsageSpool.drain(spool, scope: LiveUsageEvent.defaultScope, at: now)
        expect(blocked.events.isEmpty && !blocked.hasGaps && LiveUsageSpool.hasPending(spool))
        try FileManager.default.removeItem(at: spool.appendingPathComponent(LiveUsageSpool.lockName))
        expectEqual(LiveUsageSpool.drain(spool, scope: LiveUsageEvent.defaultScope, at: now).events.map(\.id), ["held"])
        expectFalse(LiveUsageSpool.drain(root.appendingPathComponent("absent"), scope: LiveUsageEvent.defaultScope).hasGaps)

        // A figure outside 0–100 is unknown, and it never replaces a valid one.
        let wild = try LiveUsageSpool.record(id: "wild", scope: LiveUsageEvent.defaultScope, at: now, limits: limits(150))
        try LiveUsageSpool.write(wild, id: "wild", at: now, to: spool)
        let odd = LiveUsageSpool.drain(spool, scope: LiveUsageEvent.defaultScope, at: now)
        expectEqual(odd.events.first?.snapshot.fiveHour?.remaining, nil)
        let kept = LiveUsageFold.readings(odd.events, scope: LiveUsageEvent.defaultScope, known: known, since: .distantPast, at: now)
        expectEqual(kept.first?.fiveHour?.used, 40)
    }

    static func limits(_ used: Double, five: Date, seven: Date) -> [String: Any] {
        ["five_hour": ["used_percentage": used, "resets_at": five.timeIntervalSince1970],
         "seven_day": ["used_percentage": 30.0, "resets_at": seven.timeIntervalSince1970]]
    }

    /// Which events a scope takes: after the switch, recent, not older than what is known, on the same windows.
    func testFoldRules() {
        func event(_ id: String, _ used: Double, ago: TimeInterval, resets: Date? = nil, scope: String = LiveUsageEvent.defaultScope) -> LiveUsageEvent {
            LiveUsageEvent(id: id, scope: scope, snapshot: UsageSnapshot(fiveHour: UsageWindow(used: used, resetsAt: resets ?? reset5),
                                                                         sevenDay: UsageWindow(used: 30, resetsAt: reset7),
                                                                         sampledAt: now.addingTimeInterval(-ago), source: UsageParser.statusLineSource))
        }
        let known = UsageSnapshot(fiveHour: UsageWindow(used: 50, resetsAt: reset5), sevenDay: UsageWindow(used: 30, resetsAt: reset7),
                                  sampledAt: now.addingTimeInterval(-60))
        let switched = now.addingTimeInterval(-40)
        let events = [event("before-switch", 90, ago: 50), event("other-account", 95, ago: 10, resets: reset5.addingTimeInterval(9000)),
                      event("too-old", 80, ago: 700), event("other-scope", 99, ago: 5, scope: LiveUsageEvent.projectScope(UUID())),
                      event("same-second-b", 61, ago: 5), event("same-second-a", 66, ago: 5), event("lower-later", 58, ago: 2)]
        let readings = LiveUsageFold.readings(events, scope: LiveUsageEvent.defaultScope, known: known, since: switched, at: now)
        expectEqual(readings.map { $0.fiveHour?.used ?? -1 }, [66, 66, 66])
        expect(LiveUsageFold.readings(events, scope: LiveUsageEvent.defaultScope, known: nil, since: switched, at: now).isEmpty)
    }

    /// One directory, one id, on any machine; a binding names exactly one directory; shared accounts need consent.
    func testProjectRules() throws {
        let id = ProjectBinding.stableID(forRoot: "/fixture/项目 A")
        expectEqual(id, ProjectBinding.stableID(forRoot: "/fixture/项目 A/"))
        expectEqual(id, ProjectBinding.stableID(forRoot: "/fixture/./x/../项目 A"))
        expectFalse(id == ProjectBinding.stableID(forRoot: "/fixture/项目 B"))
        expectEqual(id.uuidString.split(separator: "-")[2].first, "5")
        var account = Account(label: "Fixture A", kind: .oauth)
        let other = Account(label: "Fixture B", kind: .oauth)
        let a = ProjectBinding(name: "A", rootPath: "/fixture/项目 A", accountID: account.id, phase: .ready)
        var catalog = ProjectCatalog(projects: [a])
        expect(catalog.problem == nil)
        expectEqual(catalog.binding(rootPath: "/fixture/项目 A/")?.id, a.id)
        expect(catalog.binding(rootPath: "/fixture/项目 A/sub") == nil)
        expect(catalog.binding(rootPath: "/fixture") == nil)
        expectEqual(catalog.reservedAccountIDs, [account.id])
        expect(ProjectRules.bindingProblem(root: a.rootPath, account: other, catalog: catalog, defaultLoginAccount: nil, allowShared: false) != nil)
        let b = "/fixture/项目 B"
        expect(ProjectRules.bindingProblem(root: b, account: other, catalog: catalog, defaultLoginAccount: nil, allowShared: false) == nil)
        expect(ProjectRules.bindingProblem(root: b, account: account, catalog: catalog, defaultLoginAccount: nil, allowShared: false) != nil)
        expect(ProjectRules.bindingProblem(root: b, account: account, catalog: catalog, defaultLoginAccount: nil, allowShared: true) == nil)
        expect(ProjectRules.bindingProblem(root: b, account: other, catalog: catalog, defaultLoginAccount: other.id, allowShared: false) != nil)
        expect(ProjectRules.bindingProblem(root: a.rootPath, account: account, catalog: catalog, defaultLoginAccount: nil, allowShared: false, replacing: a.id) == nil)
        expect(ProjectRules.bindingProblem(root: b, account: nil, catalog: catalog, defaultLoginAccount: nil, allowShared: true) != nil)
        account.enabled = false
        expect(ProjectRules.bindingProblem(root: b, account: account, catalog: catalog, defaultLoginAccount: nil, allowShared: true) != nil)
        expect(ProjectRules.launchProblem(a, account: account) != nil)
        account.enabled = true
        expect(ProjectRules.launchProblem(a, account: account) == nil)
        expect(ProjectRules.launchProblem(a, account: nil) != nil)
        var pending = a; pending.phase = .preparing
        expect(ProjectRules.launchProblem(pending, account: account) != nil)
        var tampered = a; tampered.id = UUID()
        expect(ProjectCatalog(projects: [tampered]).problem != nil)
        catalog.projects.append(a)
        expect(catalog.problem != nil)
        for key in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            expect(ProjectRules.clearedEnvironment.contains(key))
        }
        expect(a.eventScope == LiveUsageEvent.projectScope(a.id))
        let decoded = try JSONDecoder().decode(ProjectCatalog.self, from: JSONEncoder().encode(catalog))
        expectEqual(decoded, catalog)
    }

    /// An import only adds, never overwrites, survives a failure or a crash at every step, and leaves relay off.
    func testImportPlanAndTransaction() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/import-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = root.appendingPathComponent("secrets"), libraryFile = root.appendingPathComponent("accounts.json")
        try SecureFiles.directory(secrets)
        func login(_ name: String, refresh: Bool = true, expires: Double = 4_102_444_800_000) -> Data {
            var oauth: [String: Any] = ["accessToken": "fixture-access-\(name)", "expiresAt": expires]
            if refresh { oauth["refreshToken"] = "fixture-refresh-\(name)" }
            return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        }
        func identity(_ name: String) -> Data { try! JSONSerialization.data(withJSONObject: ["accountUuid": "fixture-stable-\(name)"]) }
        let existing = Account(label: "Fixture existing", kind: .oauth)
        var base = Library(); base.accounts = [existing]; base.activeID = existing.id; base.preferences.autoRelay = true
        try SecureFiles.write(login("existing"), to: secrets.appendingPathComponent(existing.id.uuidString))
        try SecureFiles.write(identity("existing"), to: secrets.appendingPathComponent(CredentialImport.identityName(existing.id)))
        // JSONEncoder's key order is not stable from one call to the next, so the bytes on disk are the reference.
        let baseBytes = try JSONEncoder().encode(base)
        try SecureFiles.write(baseBytes, to: libraryFile)
        let read: (UUID) throws -> Data? = { try? Data(contentsOf: secrets.appendingPathComponent($0.uuidString)) }
        let readIdentity: (UUID) throws -> Data? = { try? Data(contentsOf: secrets.appendingPathComponent(CredentialImport.identityName($0))) }
        func plan(_ items: [TransferItem], _ library: Library) throws -> CredentialImport.Plan {
            try CredentialImport.plan(items, into: library, stored: read, storedIdentity: readIdentity, at: now)
        }
        let oauth = TransferItem(localID: UUID(), label: " Fixture OAuth ", kind: .oauth, credential: login("oauth"), identity: identity("oauth"))
        let token = TransferItem(localID: UUID(), label: "Fixture token", kind: .setupToken, credential: login("token", refresh: false))
        // The archive is checked as a whole first.
        expectThrows(try plan([oauth, oauth], base))
        expectThrows(try plan([TransferItem(localID: UUID(), label: "x", kind: .setupToken, credential: login("kind"))], base))
        expectThrows(try plan([TransferItem(localID: UUID(), label: "x", kind: .setupToken, credential: login("old", refresh: false, expires: 1000))], base))
        expectThrows(try plan([TransferItem(localID: UUID(), label: "  ", kind: .oauth, credential: login("blank"))], base))
        var twin = oauth; twin.localID = UUID()
        expectThrows(try plan([oauth, twin], base))
        let sameID = TransferItem(localID: existing.id, label: "x", kind: .oauth, credential: login("existing"))
        let clash = TransferItem(localID: existing.id, label: "x", kind: .oauth, credential: login("newer-elsewhere"))
        let sameAccount = TransferItem(localID: UUID(), label: "x", kind: .oauth, credential: login("copy"), identity: identity("existing"))
        let decided = try plan([oauth, token, sameID, sameAccount], base)
        expectEqual(decided.additions.count, 2); expectEqual(decided.skipped, 2); expectEqual(decided.conflicts, 0)
        expectEqual(try plan([clash], base).conflicts, 1)
        expectEqual(decided.additions.map(\.label), ["Fixture OAuth", "Fixture token"])
        expect(decided.additions.allSatisfy { !$0.enabled && $0.usage == nil })
        expectEqual(decided.additions.last?.usageCapability, .unavailable)

        // A failure at each step before the commit leaves nothing behind and the library as it was.
        for point in ["journal", "staging", "links"] {
            expectThrows(try CredentialImport.commit(decided, base: base, secrets: secrets, libraryFile: libraryFile, failAt: point))
            expectEqual(try Data(contentsOf: libraryFile), baseBytes)
            expectEqual(try FileManager.default.contentsOfDirectory(atPath: secrets.path).sorted(),
                        [existing.id.uuidString, CredentialImport.identityName(existing.id)].sorted())
        }
        // A secret already under the name stops the import without replacing it.
        let squatter = secrets.appendingPathComponent(oauth.localID.uuidString)
        try SecureFiles.write(Data("fixture-unrelated".utf8), to: squatter)
        expectThrows(try CredentialImport.commit(decided, base: base, secrets: secrets, libraryFile: libraryFile))
        expectEqual(try Data(contentsOf: squatter), Data("fixture-unrelated".utf8))
        try FileManager.default.removeItem(at: squatter)
        // A crash after the files and before the library: recovery removes exactly what the import made.
        expectThrows(try CredentialImport.commit(decided, base: base, secrets: secrets, libraryFile: libraryFile, failAt: "crash:links"))
        expect(FileManager.default.fileExists(atPath: secrets.appendingPathComponent(oauth.localID.uuidString).path))
        try CredentialImport.recover(secrets: secrets, libraryFile: libraryFile)
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: secrets.path).sorted(),
                    [existing.id.uuidString, CredentialImport.identityName(existing.id)].sorted())
        // A commit interrupted before its cleanup keeps the new accounts.
        let result = try CredentialImport.commit(decided, base: base, secrets: secrets, libraryFile: libraryFile, failAt: "afterCommit")
        try CredentialImport.recover(secrets: secrets, libraryFile: libraryFile)
        expectEqual(result.added, 2)
        expectEqual(result.library.activeID, existing.id)
        expectEqual(result.library.preferences.autoRelay, false)
        let saved = try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryFile))
        expectEqual(saved.accounts.count, 3)
        for item in [oauth, token] {
            let file = secrets.appendingPathComponent(item.localID.uuidString)
            expectEqual(try Data(contentsOf: file), item.credential)
            expectEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue, 0o600)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: secrets.path).filter { $0.contains("import") }
        expect(leftovers.isEmpty)
        // Importing the same archive again adds nothing.
        let again = try plan([oauth, token], saved)
        expectEqual(again.additions.count, 0); expectEqual(again.skipped, 2)
        let unchanged = try CredentialImport.commit(again, base: saved, secrets: secrets, libraryFile: libraryFile)
        expectEqual(unchanged.library.preferences.autoRelay, saved.preferences.autoRelay)
    }
}
