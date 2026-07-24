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
    private var setupPoll: Timer?
    /// True in the instance started by an automatic post-grant relaunch. It stops
    /// a failed grant from restarting the app in a loop.
    private let didRelaunchForAccessibility =
        CommandLine.arguments.contains("--relaunched-after-accessibility-grant")
    private var announceReadyWhenComplete = true
    /// Setup just finished. Say so in the menu bar for a few seconds, because a
    /// silent transition leaves the user with no idea whether it worked.
    private var readyBannerUntil: Date?
    private var previousSetupComplete = false
    private var bannerTimer: Timer?
    /// Shown the moment a wake phrase is heard. Without it the user says the
    /// phrase, the green prompt vanishes, and nothing visibly acknowledges that
    /// anything was heard at all.
    private var wakeBannerUntil: Date?
    private var wakeBannerTimer: Timer?
    private var previousStatus: AppController.Status?
    /// Seeded from the current value so an install that is already verified does
    /// not re-announce itself on every launch.
    private lazy var previousVerified: Bool = controller.isVoiceStateVerified
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
            announceReadyWhenComplete = false
            announceReady()
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

        noticeWakeIfStarting()
        noticeFirstVerifiedLaunch()
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
            addNote("Hey Codex restarts itself to pick up the permission. Use this if it has not.")
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
                menu.addItem(item("Voice Already Closed — Reset", #selector(rearmVoice)))
            }
            menu.addItem(.separator())
        }
        if !controller.isChatGPTInstalled {
            addNote("The ChatGPT desktop app was not found.")
            menu.addItem(item("Get ChatGPT for Mac…", #selector(openChatGPTDownload)))
            menu.addItem(.separator())
        }
        // Until a launch has actually been observed to work, put the test first
        // and weight it. Otherwise the user's first spoken phrase doubles as the
        // app's first ever attempt, with nothing proven and no way to see that
        // the shortcut went nowhere.
        if !controller.isVoiceStateVerified {
            menu.addItem(action("Try It: Test ChatGPT Voice", #selector(testVoiceShortcut)))
            addNote("Confirms the hotkey matches before you rely on the phrase.")
        } else {
            menu.addItem(item("Test ChatGPT Voice Shortcut", #selector(testVoiceShortcut)))
        }
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
        // An icon alone cannot say "you still need to do something here", and a
        // lone symbol among a dozen menu bar symbols goes unnoticed. During
        // setup the item carries bracketed, coloured text instead.
        // Numbered steps so progress is visible from the menu bar alone. After
        // granting the microphone the label has to visibly change, or it looks
        // like nothing happened.
        let label: String
        let tint: NSColor?
        switch state {
        case .needsMicrophone:
            label = "<Set up Hey Codex: step 1 of 2>"
            tint = .systemOrange
        case .microphoneBlocked:
            label = "<Microphone blocked: step 1 of 2>"
            tint = .systemRed
        case .needsAccessibility:
            label = "<Set up Hey Codex: step 2 of 2>"
            tint = .systemOrange
        case .accessibilityPendingRelaunch:
            label = "<Finishing setup...>"
            tint = .systemOrange
        case .ready:
            if let until = wakeBannerUntil, Date() < until {
                label = "<Opening ChatGPT Voice...>"
                tint = .systemBlue
            } else if !controller.isVoiceStateVerified {
                // Outstanding business, not a notification. It stays until a
                // launch has actually been seen to work, exactly as the setup
                // label stays until the permissions are granted.
                label = "<Ready: click to test>"
                tint = .systemOrange
            } else if let until = readyBannerUntil, Date() < until {
                // The one genuinely transient message: setup just finished.
                label = "<All set. Say \u{201C}\(controller.settings.wakePhrase)\u{201D} anytime>"
                tint = .systemGreen
            } else {
                label = ""
                tint = nil
                readyBannerUntil = nil
                wakeBannerUntil = nil
            }
        }

        let name: String
        if !state.isComplete {
            name = "exclamationmark.circle.fill"
        } else if !controller.isListening {
            name = "pause.circle"
        } else if controller.isArmed {
            name = "dot.radiowaves.left.and.right"
        } else {
            name = "lock.fill"
        }

        guard let button = statusItem.button else { return }
        button.imagePosition = label.isEmpty ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        if let tint {
            button.attributedTitle = NSAttributedString(string: " " + label, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: tint,
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
        }

        if var image = NSImage(systemSymbolName: name, accessibilityDescription: "Hey Codex") {
            if let tint,
               let coloured = image.withSymbolConfiguration(.init(paletteColors: [tint])) {
                // A template image renders monochrome, so colour needs the flag off.
                image = coloured
                image.isTemplate = false
            } else {
                image.isTemplate = true
            }
            button.image = image
        }
    }

    /// Hold "Say “Hey Codex”" in the menu bar for long enough to be read, then
    /// go back to the quiet icon.
    private func announceReady() {
        readyBannerUntil = Date().addingTimeInterval(20)
        bannerTimer?.invalidate()
        bannerTimer = Timer.scheduledTimer(withTimeInterval: 20.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.readyBannerUntil = nil
                self?.refreshMenu()
            }
        }
        refreshMenu()
    }

    /// The moment a launch is first observed to actually work, setup is over in
    /// the way the user cares about. Say so: the permission banner fired earlier,
    /// when the only honest thing to say was "click to test".
    private func noticeFirstVerifiedLaunch() {
        let verified = controller.isVoiceStateVerified
        let shouldAnnounce = verified && !previousVerified
        // Record the transition BEFORE announcing. announceReady refreshes the
        // menu, which lands back here; a deferred assignment runs on the way out
        // and so never breaks that loop.
        previousVerified = verified
        if shouldAnnounce { announceReady() }
    }

    /// Turn "the shortcut is being sent" into something the user can see.
    private func noticeWakeIfStarting() {
        let status = controller.status
        let isNewWake = status == .activating && previousStatus != .activating
        previousStatus = status
        guard isNewWake else { return }
        readyBannerUntil = nil
        wakeBannerUntil = Date().addingTimeInterval(4)
        wakeBannerTimer?.invalidate()
        wakeBannerTimer = Timer.scheduledTimer(withTimeInterval: 4.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.wakeBannerUntil = nil
                self?.refreshMenu()
            }
        }
    }

    private func startSetupPolling() {
        setupPoll?.invalidate()
        setupPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.controller.setupState.isComplete else {
                    self.setupPoll?.invalidate()
                    self.setupPoll = nil
                    if self.announceReadyWhenComplete {
                        self.announceReadyWhenComplete = false
                        self.announceReady()
                    }
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
