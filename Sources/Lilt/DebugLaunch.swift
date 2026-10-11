import SwiftUI
import LiltCore

/// The window's content. In debug builds a few environment variables put the app straight into a state
/// worth looking at, so screens can be checked without clicking through them. Release builds ignore them.
struct RootView: View {
    @Bindable var model: AppModel
    var body: some View {
        #if DEBUG
        Group {
            if ProcessInfo.processInfo.environment["LILT_PANEL"] == "1" {
                // The menu bar panel cannot be opened from outside; show the same view in the window instead.
                MenuPanel(model: model).background(.regularMaterial).fixedSize()
            } else {
                MainView(model: model)
            }
        }
        .task { DebugLaunch.apply(to: model) }
        #else
        MainView(model: model)
        #endif
    }
}

#if DEBUG
enum DebugLaunch {
    /// LILT_APPEARANCE=dark|light, LILT_DEMO=1, LILT_PAGE=overview|accounts|scope|diagnostics, LILT_RELAY=1,
    /// LILT_SIMULATE=1 (demo quota reaches the threshold), LILT_PENDING=1 (shows the "applied, not yet verified" notice),
    /// LILT_ROSTER=1 (seven demo accounts), LILT_SWITCH=<index>, LILT_STOPPED=1, LILT_UNREAD=1, LILT_AGE=<seconds>.
    @MainActor static func apply(to model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        if let look = environment["LILT_APPEARANCE"] { NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua) }
        if environment["LILT_DEMO"] == "1" { model.startDemo() }
        // LILT_ROSTER=1 widens the demo to seven accounts that cover the states quota cells have to draw:
        // low, full with no reset yet, a window past its reset, and one window missing.
        if environment["LILT_ROSTER"] == "1", model.demo { seedRoster(model) }
        if let name = environment["LILT_PAGE"], let page = AppModel.Page.allCases.first(where: { "\($0)" == name }) { model.selectedPage = page }
        if environment["LILT_RELAY"] == "1" { model.setAutoRelay(true) }
        if environment["LILT_SIMULATE"] == "1" { Task { await model.simulateThreshold() } }
        if environment["LILT_PENDING"] == "1" { model.appliedPending = true }
        // LILT_STATUSLINE=install|uninstall exercises the status line bridge. Only inside a fake home
        // (CFFIXED_USER_HOME), so a check can never touch the real ~/.claude/settings.json.
        if let action = environment["LILT_STATUSLINE"], let fake = environment["CFFIXED_USER_HOME"], !fake.isEmpty,
           FileManager.default.homeDirectoryForCurrentUser.path == fake {
            do {
                if action == "install" { try StatusLineBridge.install(); StatusLineBridge.setLabel("Fixture") }
                if action == "uninstall" { try StatusLineBridge.uninstall() }
                print("statusline \(action): ok, installed=\(StatusLineBridge.isInstalled)")
            } catch { print("statusline \(action): \(error)") }
        }
        // LILT_SWITCH=<index> switches to that demo account after a moment, to watch the hand-off.
        if let index = environment["LILT_SWITCH"].flatMap(Int.init), model.demo, model.accounts.indices.contains(index) {
            let id = model.accounts[index].id
            Task { try? await Task.sleep(for: .seconds(1.5)); await model.apply(id) }
        }
        // LILT_STOPPED=1 stops the last demo account, LILT_UNREAD=1 drops the second-to-last one's reading.
        if environment["LILT_STOPPED"] == "1", let last = model.accounts.last, model.demo { model.update(last.id) { $0.enabled = false } }
        if environment["LILT_UNREAD"] == "1", model.accounts.count > 1, model.demo { model.update(model.accounts[model.accounts.count - 2].id) { $0.usage = nil } }
        // LILT_AGE=<seconds> backdates the demo readings, to look at how old readings are shown.
        if let age = environment["LILT_AGE"].flatMap(Double.init), model.demo {
            for account in model.accounts { model.update(account.id) { $0.usage?.sampledAt = Date.now.addingTimeInterval(-age) } }
        }
    }
    @MainActor private static func seedRoster(_ model: AppModel) {
        let hour: TimeInterval = 3600, day: TimeInterval = 86400
        // (label, 5-hour used, 5-hour reset, 7-day used, 7-day reset). A nil reset with 0 used is a window that has not started.
        let rows: [(String, Double?, TimeInterval?, Double?, TimeInterval?)] = [
            ("001", 58, 3 * hour, 8, 6.9 * day),
            ("003", 95, 28 * 60, 40, 5 * day),
            ("004", 0, nil, 31, 4 * day),
            ("005", 0, nil, 10, 6 * day),
            ("006", 70, -10 * 60, 67, 1 * day),
            ("007", 0, nil, 20, -5 * 60),
            ("009", 0, nil, 0, 6 * day),
        ]
        model.library.accounts = rows.map { label, fiveUsed, fiveReset, sevenUsed, sevenReset in
            var account = Account(label: label, kind: .oauth)
            account.usage = UsageSnapshot(fiveHour: fiveUsed.map { UsageWindow(used: $0, resetsAt: fiveReset.map { .now.addingTimeInterval($0) }) },
                                          sevenDay: sevenUsed.map { UsageWindow(used: $0, resetsAt: sevenReset.map { .now.addingTimeInterval($0) }) },
                                          source: "本地演示数据")
            account.usageCapability = .verified; account.hotSwitchCapability = .verified
            return account
        }
        model.library.activeID = model.accounts.first?.id
    }
}
#endif
