import SwiftUI

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
    /// LILT_SIMULATE=1 (demo quota reaches the threshold), LILT_PENDING=1 (shows the "applied, not yet verified" notice).
    @MainActor static func apply(to model: AppModel) {
        let environment = ProcessInfo.processInfo.environment
        if let look = environment["LILT_APPEARANCE"] { NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua) }
        if environment["LILT_DEMO"] == "1" { model.startDemo() }
        if let name = environment["LILT_PAGE"], let page = AppModel.Page.allCases.first(where: { "\($0)" == name }) { model.selectedPage = page }
        if environment["LILT_RELAY"] == "1" { model.setAutoRelay(true) }
        if environment["LILT_SIMULATE"] == "1" { Task { await model.simulateThreshold() } }
        if environment["LILT_PENDING"] == "1" { model.appliedPending = true }
    }
}
#endif
