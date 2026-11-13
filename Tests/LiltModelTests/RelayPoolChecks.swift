import Foundation
import LiltCore

/// `lilt <account>…` through the app model: one account locks the default login on it, several keep relay among
/// them, the first listed with room is taken, a switch by hand in the app outside the pool ends it, and `lilt all`
/// frees relay again. Fixture accounts only, in the local preview model.
@MainActor func relayPoolChecks() async throws {
    func snapshot(_used used: Double) -> UsageSnapshot {
        UsageSnapshot(fiveHour: UsageWindow(used: used, resetsAt: .now.addingTimeInterval(3600)),
                      sevenDay: UsageWindow(used: 20, resetsAt: .now.addingTimeInterval(86400)), sampledAt: .now)
    }
    func account(_ label: String, used: Double) -> Account {
        var account = Account(label: label, kind: .oauth)
        account.usage = snapshot(_used: used); account.usageCapability = .verified; account.hotSwitchCapability = .verified
        return account
    }
    var library = Library()
    let a = account("Fixture A", used: 100), b = account("Fixture B", used: 20), c = account("Fixture C", used: 10)
    var off = account("Fixture Off", used: 0); off.enabled = false
    library.accounts = [a, b, c, off]; library.activeID = a.id; library.preferences.autoRelay = true
    var retryTime = Date.now
    let model = AppModel(preview: library, retryClock: { retryTime })
    func set(_ id: UUID, used: Double) { model.update(id) { $0.usage = snapshot(_used: used) } }

    // One account: switch to it and lock it there.
    var reply = await model.useAccounts([c.id])
    precondition(reply.ok && model.active?.id == c.id && model.relayPool == [c.id], "lilt C switches and locks: \(reply.lines)")
    precondition(reply.lines.contains { $0.contains("已锁定“Fixture C”") } && model.relayPoolSummary?.contains("已锁定") == true)
    precondition(reply.accounts?.first { $0.id == b.id }?.inPool == false && reply.pool == [c.id])
    set(c.id, used: 100)
    await model.relay()
    precondition(model.active?.id == c.id && model.relayPause?.contains("已锁定“Fixture C”") == true, "A locked account is never left")

    // Several: the first listed with room is taken (A is spent), and relay stays among them.
    reply = await model.useAccounts([a.id, b.id, a.id])
    precondition(reply.ok && model.active?.id == b.id && model.library.preferences.relayPool == [a.id, b.id], "lilt A B takes B")
    set(b.id, used: 100); set(c.id, used: 10)
    await model.relay()
    precondition(model.active?.id == b.id && model.relayPause != nil, "C is outside the pool, so nothing qualifies")
    set(a.id, used: 30)
    retryTime = retryTime.addingTimeInterval(901) // A waits for its reset; a pause looks again within 15 minutes
    await model.relay()
    precondition(model.active?.id == a.id, "Relay hands off inside the pool")

    // Already inside the pool: no switch.
    reply = await model.useAccounts([b.id, a.id])
    precondition(reply.ok && model.active?.id == a.id && reply.lines.first?.contains("没有切换") == true)

    // Refused: a disabled account, and nothing at all.
    let disabled = await model.useAccounts([off.id]), empty = await model.useAccounts([])
    precondition(!disabled.ok && !empty.ok && model.library.preferences.relayPool == [b.id, a.id])

    // A switch by hand in the app to an account outside the pool ends it; inside, it stays.
    _ = await model.apply(b.id)
    precondition(model.library.preferences.relayPool == [b.id, a.id], "A switch inside the pool keeps it")
    _ = await model.apply(c.id)
    precondition(model.library.preferences.relayPool == nil && model.relayPool == nil, "A switch outside the pool ends it")

    // `lilt all`, and removing the last account of a pool, free relay.
    _ = await model.useAccounts([c.id])
    reply = model.useAllAccounts()
    precondition(reply.ok && model.relayPool == nil && reply.lines == ["接力范围已恢复全部账号。"])
    _ = await model.useAccounts([b.id, c.id])
    model.remove(b.id)
    precondition(model.library.preferences.relayPool == [c.id], "A removed account leaves the pool")
    print("PASS: lilt and the relay pool — lock on one account, relay among several, first with room taken, refusals, a switch by hand outside the pool ends it, lilt all.")
}
