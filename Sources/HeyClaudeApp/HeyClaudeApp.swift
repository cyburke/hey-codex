import AppKit

/// Hey Codex is intentionally an accessory/menu-bar app: it has no floating
/// notch or overlay and never takes focus from the current app.
@main
@MainActor
enum HeyCodexMain {
    static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var settingsWindow: SettingsWindowController?
    private var firstRunSetupWindow: FirstRunSetupWindowController?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "Hey Codex listener") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "Hey Codex"
        statusItem.menu = menu
        menu.delegate = self
        controller.onStatusChange = { [weak self] in self?.refreshMenu() }
        beginLaunchFlow()
        refreshMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        menu.removeAllItems()
        let state = NSMenuItem(title: controller.status.menuText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        if !controller.isArmed {
            menu.addItem(item("Re-arm Voice", #selector(rearmVoice)))
        }
        let endVoice = item("End ChatGPT Voice & Re-arm", #selector(endVoiceSession))
        endVoice.isEnabled = !controller.isArmed
        menu.addItem(endVoice)
        menu.addItem(.separator())
        if controller.needsFirstRunSetup {
            menu.addItem(item("Complete Setup…", #selector(openFirstRunSetup)))
            menu.addItem(item("Enable ChatGPT Voice Shortcut…", #selector(enableVoiceShortcut)))
            menu.addItem(item("Test ChatGPT Voice Shortcut", #selector(testVoiceShortcut)))
        }
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item("Updates…", #selector(showUpdates)))
        menu.addItem(.separator())
        let privacy = NSMenuItem(title: "All listening stays on this Mac", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)
        menu.addItem(item("Quit Hey Codex", #selector(quit)))

        let name: String
        if !controller.isListening {
            name = "pause.circle"
        } else if controller.isArmed {
            name = "dot.radiowaves.left.and.right"
        } else {
            name = "lock.fill"
        }
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Hey Codex listener") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    @objc private func rearmVoice() { controller.rearmVoice() }
    @objc private func endVoiceSession() { controller.endVoiceSession() }
    @objc private func openFirstRunSetup() { showFirstRunSetup() }
    @objc private func enableVoiceShortcut() { controller.requestVoiceShortcutPermission() }
    @objc private func testVoiceShortcut() { controller.testVoiceShortcut() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func showUpdates() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
        let alert = NSAlert()
        alert.messageText = "Hey Codex \(version)"
        alert.informativeText = "This local build does not contact the internet or install updates automatically. Update delivery will be enabled only after signed, notarized releases are configured and tested."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openSettings() {
        let window = settingsWindow ?? SettingsWindowController(controller: controller)
        settingsWindow = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func beginLaunchFlow() {
        // Do not request microphone permission while the app is launching.
        // The first-run window owns that explicit, visible user action.
        if controller.isMicrophoneAuthorized {
            controller.startListening()
            if controller.needsFirstRunSetup { showFirstRunSetup() }
        } else {
            showFirstRunSetup()
        }
    }

    private func showFirstRunSetup() {
        let window = firstRunSetupWindow ?? FirstRunSetupWindowController(controller: controller) { [weak self] in
            self?.firstRunSetupWindow = nil
            self?.refreshMenu()
        }
        firstRunSetupWindow = window
        window.showWindowOnTop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if controller.needsFirstRunSetup {
            showFirstRunSetup()
        } else {
            openSettings()
        }
        return true
    }
}
