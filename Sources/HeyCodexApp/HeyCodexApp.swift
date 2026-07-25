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
    // variableLength, not squareLength: the item has to widen to fit the
    // setup label. A square item silently clips every title to nothing.
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var settingsWindow: SettingsWindowController?
    private var enrollmentWindow: WakePhraseEnrollmentWindowController?
    private var setupWindow: SetupWindowController?
    private var setupPoll: Timer?
    /// True in the instance started by an automatic post-grant relaunch. It stops
    /// a failed grant from restarting the app in a loop.
    private let didRelaunchForAccessibility =
        CommandLine.arguments.contains("--relaunched-after-accessibility-grant")
    private var isRefreshingMenu = false
    static let accessibilityRelaunchArgument = "--relaunched-after-accessibility-grant"
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
        // Discovery is handled by the status item carrying readable text, which
        // works regardless of activation state. Programmatically opening the
        // menu at launch does not, so it is not relied on.
        if didRelaunchForAccessibility {
            // Came back from the automatic post-grant relaunch: pick the flow up
            // where it left off rather than leaving a blank menu bar.
            showSetup(startAt: .permissions)
        } else if controller.needsFirstRunSetup {
            // Open on the first unfinished step. Permissions carry over a
            // reinstall, so a returning user should land on the test, not be
            // walked through the welcome text again.
            showSetup(startAt: SetupWindowController.startingPage(for: controller))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        // A menu rebuild can be triggered from inside a rebuild: a banner sets
        // state, which refreshes the menu. One level is all that is ever needed,
        // and re-entering is how a stack overflow starts.
        guard !isRefreshingMenu else { return }
        isRefreshingMenu = true
        defer { isRefreshingMenu = false }

        menu.removeAllItems()
        let state = controller.setupState

        if state.isComplete, controller.isVoiceStateVerified {
            buildReadyMenu()
        } else {
            buildSetupMenu(state)
        }

        menu.addItem(.separator())
        menu.addItem(item("Report an Issue…", #selector(reportIssue)))
        menu.addItem(item("About Hey Codex", #selector(showAbout)))
        menu.addItem(.separator())
        let privacy = NSMenuItem(title: "Everything you say stays on this Mac", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        menu.addItem(privacy)
        menu.addItem(item("Quit Hey Codex", #selector(quit)))
        refreshStatusIcon(state)
    }

    /// Setup lives in a window now, not in the menu. A menu could not carry the
    /// explanation that earns an always-listening microphone permission, and it
    /// closes the instant the user clicks anything, which is exactly when they
    /// leave for System Settings.
    private func buildSetupMenu(_ state: SetupState) {
        addHeading("Finish setting up Hey Codex")
        menu.addItem(action("Open Setup…", #selector(openSetup)))
        switch state {
        case .needsMicrophone:            addNote("Next up: the microphone.")
        case .microphoneBlocked:          addNote("Microphone access is switched off right now.")
        case .needsAccessibility:         addNote("Next up: Accessibility.")
        case .accessibilityPendingRelaunch: addNote("Restarting to pick up that permission…")
        case .ready:                      addNote("Just the test left.")
        }
        if !controller.isChatGPTInstalled {
            menu.addItem(.separator())
            addNote("The ChatGPT desktop app is not installed.")
            menu.addItem(item("Get ChatGPT for Mac…", #selector(openChatGPTDownload)))
        }
    }

    private func buildReadyMenu() {
        // Always name the phrase. "Listening locally" told the user nothing
        // about what to actually say.
        let title = controller.isListening && controller.isArmed
            ? "Listening for “\(controller.settings.wakePhrase)”"
            : controller.status.menuText
        let state = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let update = controller.availableUpdate {
            menu.addItem(action("Update available: \(update.version)", #selector(openUpdate)))
        }
        menu.addItem(.separator())

        if !controller.isArmed {
            menu.addItem(item("End Voice Session", #selector(endVoiceSession)))
            if !controller.isVoiceStateVerified {
                menu.addItem(item("Voice Already Closed, Reset", #selector(rearmVoice)))
            }
            menu.addItem(.separator())
        }
        if !controller.isChatGPTInstalled {
            addNote("The ChatGPT desktop app is not installed.")
            menu.addItem(item("Get ChatGPT for Mac…", #selector(openChatGPTDownload)))
            menu.addItem(.separator())
        }
        // Until a launch has actually been observed to work, put the test first
        // and weight it. Otherwise the user's first spoken phrase doubles as the
        // app's first ever attempt, with nothing proven and no way to see that
        // the shortcut went nowhere.
        if !controller.isVoiceStateVerified {
            menu.addItem(action("Try It Now: Test ChatGPT Voice", #selector(testVoiceShortcut)))
            addNote("Worth doing once, so you know the hotkey lines up.")
        } else {
            menu.addItem(item("Test ChatGPT Voice Shortcut", #selector(testVoiceShortcut)))
        }
        let phraseTitle = controller.hasEnrolledWakePhrase
            ? "Wake Phrase: “\(controller.settings.wakePhrase)”…"
            : "Use My Own Wake Phrase…"
        menu.addItem(item(phraseTitle, #selector(enrollWakePhrase)))
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item("Setup & Diagnostics…", #selector(openSetup)))
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
        // No coloured labels. Setup is a window now, and everything is managed by
        // clicking this icon, so the icon should look like one thing that always
        // means the same thing rather than a status marquee.
        let name: String
        if !state.isComplete {
            name = "exclamationmark.circle"
        } else if !controller.isListening {
            name = "pause.circle"
        } else if controller.isArmed {
            name = "dot.radiowaves.left.and.right"
        } else {
            name = "lock.fill"
        }
        guard let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Hey Codex") {
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = state.isComplete
            ? "Hey Codex - listening for “\(controller.settings.wakePhrase)”"
            : "Hey Codex - setup not finished"
    }

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
                // macOS has recorded the grant but this process was told no and
                // never will be told otherwise. The user already did their part,
                // so finish it for them rather than asking for another click.
                if self.controller.setupState == .accessibilityPendingRelaunch,
                   !self.didRelaunchForAccessibility {
                    self.setupPoll?.invalidate()
                    self.setupPoll = nil
                    self.controller.relaunch(reason: Self.accessibilityRelaunchArgument)
                    return
                }
                self.refreshMenu()
            }
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
    }

    @objc private func openSetup() {
        showSetup(startAt: SetupWindowController.startingPage(for: controller))
    }

    @objc private func relaunchApp() { controller.relaunch() }

    private func showSetup(startAt page: SetupWindowController.Page = .welcome) {
        let window = setupWindow ?? SetupWindowController(controller: controller, startAt: page) { [weak self] in
            self?.setupWindow = nil
            self?.refreshMenu()
        }
        setupWindow = window
        window.present()
    }

    @objc private func openChatGPTDownload() {
        NSWorkspace.shared.open(URL(string: "https://openai.com/chatgpt/download/")!)
    }

    /// Open the status menu programmatically.
    ///
    /// `performClick` does not reliably show a status item's menu when the app
    /// is not frontmost, which is exactly the situation here: the user is in
    /// System Settings, not in Hey Codex. `popUp` does work, but refuses while
    /// the menu is attached to the status item, so it is detached for the call.
    private func reopenMenu() {
        refreshMenu()
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        statusItem.menu = nil
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.maxY + 5),
                   in: button)
        statusItem.menu = menu
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
            Say a phrase, ChatGPT Voice opens. That is the whole idea.

            Hey Codex listens on this Mac for one phrase and nothing else, then \
            presses the same Voice hotkey you set up in ChatGPT. No recording, \
            no uploads, no account.

            Once a day it asks GitHub whether there is a newer version, which \
            you can switch off in Settings. It never installs anything by itself.

            Free and open source under GPL-3.0, built on the excellent \
            littlemelon77/hey-claude.
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
        controller.needsFirstRunSetup ? openSetup() : openSettings()
        return true
    }
}
