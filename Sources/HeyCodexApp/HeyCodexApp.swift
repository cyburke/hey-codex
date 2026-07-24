import AppKit
import HeyCodexKit

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
    private var enrollmentWindow: WakePhraseEnrollmentWindowController?
    private var setupPoll: Timer?
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
        startSetupPolling()
        // Show the user where Hey Codex lives, once, on the very first launch
        // with setup outstanding. An accessory app that appears silently among
        // a dozen other menu bar icons is an app nobody finds.
        if controller.needsFirstRunSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.reopenMenu()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        menu.removeAllItems()
        let state = controller.setupState

        if state.isComplete {
            buildReadyMenu()
        } else {
            buildSetupMenu(state)
        }

        menu.addItem(.separator())
        menu.addItem(item("Report an Issue…", #selector(reportIssue)))
        menu.addItem(item("About Hey Codex", #selector(showAbout)))
        menu.addItem(.separator())
        let privacy = NSMenuItem(title: "All listening stays on this Mac", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)
        menu.addItem(item("Quit Hey Codex", #selector(quit)))
        refreshStatusIcon(state)
    }

    /// Setup lives in the menu, not in a window. A menu cannot be lost behind
    /// another app, it teaches the user where Hey Codex actually lives, and it
    /// is still correct when they come back from System Settings.
    private func buildSetupMenu(_ state: SetupState) {
        switch state {
        case .needsMicrophone:
            addHeading("Hey Codex needs two permissions")
            menu.addItem(action("Step 1 of 2: Allow Microphone…", #selector(grantMicrophone)))
            addNote("Listening happens on this Mac. Nothing is recorded.")
        case .microphoneBlocked:
            addHeading("Microphone access is switched off")
            menu.addItem(action("Open Microphone Settings…", #selector(openMicrophoneSettings)))
            addNote("Turn on Hey Codex, then come back to this menu.")
        case .needsAccessibility:
            addHeading("One more permission")
            menu.addItem(action("Step 2 of 2: Allow Accessibility…", #selector(grantAccessibility)))
            addNote("This is what lets Hey Codex press the ChatGPT hotkey.")
        case .accessibilityPendingRelaunch:
            addHeading("Almost there")
            menu.addItem(action("Relaunch to Finish Setup", #selector(relaunchApp)))
            addNote("macOS needs Hey Codex to restart before it can use the permission.")
        case .ready:
            break
        }
        if !controller.isChatGPTInstalled {
            menu.addItem(.separator())
            addNote("The ChatGPT desktop app was not found.")
            menu.addItem(item("Get ChatGPT for Mac…", #selector(openChatGPTDownload)))
        }
    }

    private func buildReadyMenu() {
        let state = NSMenuItem(title: controller.status.menuText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let update = controller.availableUpdate {
            menu.addItem(action("Update available: \(update.version)", #selector(openUpdate)))
        }
        menu.addItem(.separator())

        if !controller.isArmed {
            menu.addItem(item("End Voice Session", #selector(endVoiceSession)))
            if !controller.isVoiceStateVerified {
                menu.addItem(item("Voice Already Closed — Reset", #selector(rearmVoice)))
            }
            menu.addItem(.separator())
        }
        if !controller.isChatGPTInstalled {
            addNote("The ChatGPT desktop app was not found.")
            menu.addItem(item("Get ChatGPT for Mac…", #selector(openChatGPTDownload)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Test ChatGPT Voice Shortcut", #selector(testVoiceShortcut)))
        let phraseTitle = controller.hasEnrolledWakePhrase
            ? "Wake Phrase: “\(controller.settings.wakePhrase)”…"
            : "Use My Own Wake Phrase…"
        menu.addItem(item(phraseTitle, #selector(enrollWakePhrase)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
    }

    private func addHeading(_ text: String) {
        let heading = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
    }

    private func addNote(_ text: String) {
        let note = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(note)
    }

    /// The one thing to do next, weighted so it reads as the next step.
    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        return entry
    }

    private func refreshStatusIcon(_ state: SetupState) {
        let name: String
        if !state.isComplete {
            // Unfinished setup should be visible without opening the menu.
            name = "exclamationmark.circle"
        } else if !controller.isListening {
            name = "pause.circle"
        } else if controller.isArmed {
            name = "dot.radiowaves.left.and.right"
        } else {
            name = "lock.fill"
        }
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Hey Codex") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
    }

    /// While setup is outstanding the state can change in System Settings, where
    /// the app gets no notification. Poll so the menu is already correct the
    /// moment the user looks at it again.
    private func startSetupPolling() {
        setupPoll?.invalidate()
        setupPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.controller.setupState.isComplete else {
                    self.setupPoll?.invalidate()
                    self.setupPoll = nil
                    self.refreshMenu()
                    return
                }
                self.refreshMenu()
            }
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    @objc private func grantMicrophone() {
        controller.requestMicrophoneAccess { [weak self] granted in
            if granted { self?.controller.startListening() }
            // The system dialog took focus. Come back and show what is next
            // rather than leaving the user to guess.
            self?.reopenMenu()
        }
    }

    @objc private func openMicrophoneSettings() { controller.openMicrophoneSettings() }

    @objc private func grantAccessibility() {
        if controller.requestAccessibility() {
            refreshMenu()
            reopenMenu()
            return
        }
        // macOS will not grant this inline. Put the user in the right pane and
        // let the poll notice when they flip the switch.
        controller.openVoiceShortcutSettings()
    }

    @objc private func relaunchApp() { controller.relaunch() }

    @objc private func openChatGPTDownload() {
        NSWorkspace.shared.open(URL(string: "https://openai.com/chatgpt/download/")!)
    }

    /// Reopen the menu so the next step is visible without the user hunting for
    /// the icon again.
    private func reopenMenu() {
        refreshMenu()
        NSApp.activate(ignoringOtherApps: true)
        statusItem.button?.performClick(nil)
    }

    @objc private func rearmVoice() { controller.rearmVoice() }
    @objc private func endVoiceSession() { controller.endVoiceSession() }
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
        // Never prompt for the microphone at launch. Permission is asked for
        // only when the user picks the step out of the menu, so the prompt
        // always has context.
        if controller.isMicrophoneAuthorized { controller.startListening() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller.needsFirstRunSetup ? reopenMenu() : openSettings()
        return true
    }
}
