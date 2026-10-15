import SwiftUI
import Carbon

@main
struct LiltApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window(AppBuild.title, id: "main") {
            RootView(model: model)
                .task { delegate.model = model; delegate.registerShortcut() }
        }
        .defaultSize(width: 760, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加账号") { delegate.showWindow(); model.requestAdd() }.keyboardShortcut("n").disabled(!model.canAdd)
            }
            CommandGroup(after: .appInfo) {
                // Mirrors the global hotkey so the menu always shows the combination chosen in Settings.
                Button("显示快速面板") { delegate.togglePanel() }
                    .keyboardShortcut(KeyEquivalent(AppDelegate.character(for: model.library.preferences.shortcutKey)), modifiers: [.command, .option])
                Button("显示管理窗口") { delegate.showWindow() }
                Button("检查更新…") { model.checkForUpdates() }.disabled(model.updater.current == nil || model.updater.working)
            }
            CommandGroup(replacing: .help) {}
        }
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Group {
                if model.autoRelay {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                } else {
                    Image(nsImage: Self.menuIcon)
                }
            }
            .accessibilityLabel(model.autoRelay ? "Lilt，自动接力已开启" : "Lilt")
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView(model: model).frame(width: 480, height: 540) }
    }

    private static let menuIcon: NSImage = {
        // Packaged builds include both resolutions; `swift run` still has a system-symbol fallback.
        guard let url = Bundle.main.url(forResource: "LiltMenu", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Lilt")!
        }
        if let retinaURL = Bundle.main.url(forResource: "LiltMenu@2x", withExtension: "png"),
           let data = try? Data(contentsOf: retinaURL),
           let retina = NSBitmapImageRep(data: data) {
            retina.size = NSSize(width: 18, height: 18)
            image.addRepresentation(retina)
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var presentMainWindow: (() -> Void)?
    var handlerInstalled = false
    var model: AppModel?
    var hotkey: EventHotKeyRef?
    private var keyObserver: NSObjectProtocol?
    override init() { super.init(); Self.shared = self }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Two copies would poll twice, answer the same hotkey and overwrite each other's account file.
        if let other = Self.otherInstance() { other.activate(); NSApp.terminate(nil); return }
        // A window or the panel coming forward means someone is about to read it: refresh rather than show a minute-old figure.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppDelegate.shared?.model?.refreshIfStale() }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.login.cancel() }
    static func otherInstance() -> NSRunningApplication? {
        let me = NSRunningApplication.current
        return NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != me.processIdentifier && !$0.isTerminated &&
            ((me.bundleIdentifier != nil && $0.bundleIdentifier == me.bundleIdentifier) || (me.executableURL != nil && $0.executableURL == me.executableURL))
        }
    }
    static func character(for keyCode: UInt32) -> Character { [37: "l", 38: "j", 40: "k"][keyCode] ?? "l" }
    func showWindow() {
        presentMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == AppBuild.title }) { window.makeKeyAndOrderFront(nil) }
    }
    /// MenuBarExtra offers no call to open its window, so this presses the status item's own button.
    /// That also works when the icon is pushed out of sight by a crowded menu bar.
    func togglePanel() {
        guard let button = statusButton() else { showWindow(); return }
        button.performClick(nil)
    }
    private func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("StatusBar") {
            if let button = Self.descendant(NSStatusBarButton.self, of: window.contentView) { return button }
        }
        return nil
    }
    private static func descendant<T: NSView>(_ type: T.Type, of view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews { if let match = descendant(type, of: child) { return match } }
        return nil
    }
    func registerShortcut() {
        #if DEBUG
        // A build launched only to be looked at must not claim the user's global shortcut.
        if ProcessInfo.processInfo.environment["LILT_NO_HOTKEY"] == "1" { return }
        #endif
        if let hotkey { UnregisterEventHotKey(hotkey) }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if !handlerInstalled {
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // The hotkey arrives while another app is frontmost; the panel needs Lilt active to take keyboard focus.
            Task { @MainActor in NSApp.activate(ignoringOtherApps: true); AppDelegate.shared?.togglePanel() }; return noErr
        }, 1, &eventType, nil, nil)
        handlerInstalled = true
        }
        let prefs = model?.library.preferences
        let result = RegisterEventHotKey(prefs?.shortcutKey ?? 37, prefs?.shortcutModifiers ?? 2304, EventHotKeyID(signature: 0x4c494c54, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr { model?.shortcutIssue = "系统拒绝注册这个快捷键，请换一个组合。" }
        else { model?.shortcutIssue = nil }
    }
}
