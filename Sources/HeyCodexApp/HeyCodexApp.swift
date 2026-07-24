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
    private var enrollmentWindow: WakePhraseEnrollmentWindowController?
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
        controller.checkForUpdates(userInitiated: false)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        menu.removeAllItems()
        let state = NSMenuItem(title: controller.status.menuText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let update = controller.availableUpdate {
            let item = item("Update available: \(update.version)", #selector(openUpdate))
            item.attributedTitle = NSAttributedString(
                string: "Update available: \(update.version)",
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Voice normally ends in ChatGPT's own panel and Hey Codex re-arms
        // itself, so these appear only while a session is held.
        if !controller.isArmed {
            menu.addItem(item("End Voice Session", #selector(endVoiceSession)))
            // Only meaningful when Hey Codex cannot see ChatGPT's Voice panel.
            // With detection working, End Voice Session already handles an
            // already-closed session; offering both would be a coin flip.
            if !controller.isVoiceStateVerified {
                menu.addItem(item("Voice Already Closed - Reset", #selector(rearmVoice)))
            }
            menu.addItem(.separator())
        }
        if controller.needsFirstRunSetup {
            // One door while setup is unfinished. Offering "Complete Setup",
            // "Enable ChatGPT Voice Shortcut" and "Test ChatGPT Voice Shortcut"
            // side by side left people guessing which one was next.
            let finish = item("Finish Setup…", #selector(openFirstRunSetup))
            finish.attributedTitle = NSAttributedString(
                string: "Finish Setup…",
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            menu.addItem(finish)
        } else {
            menu.addItem(item("Test ChatGPT Voice Shortcut", #selector(testVoiceShortcut)))
        }
        let phraseTitle = controller.hasEnrolledWakePhrase
            ? "Wake Phrase: “\(controller.settings.wakePhrase)”…"
            : "Use My Own Wake Phrase…"
        menu.addItem(item(phraseTitle, #selector(enrollWakePhrase)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(item("Report an Issue…", #selector(reportIssue)))
        menu.addItem(item("About Hey Codex", #selector(showAbout)))
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

    @objc private func openUpdate() {
        guard let update = controller.availableUpdate else { return }
        NSWorkspace.shared.open(update.url)
    }

    @objc private func checkForUpdates() {
        controller.onUpdateStatus = { [weak self] status in
            self?.controller.onUpdateStatus = nil
            let alert = NSAlert()
            switch status {
            case .upToDate:
                alert.messageText = "Hey Codex is up to date"
                alert.informativeText = "You are running \(self?.controller.appVersion ?? "")."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .available(let version, let url):
                alert.messageText = "\(version) is available"
                alert.informativeText = "You are running \(self?.controller.appVersion ?? "")."
                alert.addButton(withTitle: "View Release")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            case .failed(let reason):
                alert.messageText = "Could not check for updates"
                alert.informativeText = reason
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        controller.checkForUpdates(userInitiated: true)
    }

    @objc private func reportIssue() {
        NSWorkspace.shared.open(URL(string: "https://github.com/cyburke/hey-codex/issues")!)
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
        let alert = NSAlert()
        alert.messageText = "Hey Codex \(version)"
        alert.informativeText = """
            A local wake-word helper for ChatGPT desktop Voice.

            Nothing is recorded and nothing leaves this Mac. Hey Codex listens \
            for one phrase and sends the same keyboard shortcut you configured \
            in ChatGPT.

            The only network request it makes is a daily check with GitHub for \
            a newer release, which you can turn off in Settings. It never \
            installs anything on its own.

            GPL-3.0. A fork of littlemelon77/hey-claude.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/cyburke/hey-codex")!)
        }
    }

    @objc private func enrollWakePhrase() {
        let window = enrollmentWindow
            ?? WakePhraseEnrollmentWindowController(controller: controller,
                                                    initialPhrase: controller.settings.wakePhrase) { [weak self] in
                self?.enrollmentWindow = nil
                self?.refreshMenu()
            }
        enrollmentWindow = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        let window = settingsWindow ?? SettingsWindowController(controller: controller)
        window.onChangeWakePhrase = { [weak self] in self?.enrollWakePhrase() }
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
