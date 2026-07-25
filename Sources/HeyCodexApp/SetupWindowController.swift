import AppKit
import HeyCodexKit

/// The setup flow: three pages, in the order a first-time user needs them.
///
/// 1. What this is, and why an always-listening app is safe. This is the page
///    that earns the microphone permission, and a menu could not carry it.
/// 2. Both permissions together, each with live state, so progress is visible
///    and a revoked permission is obvious later.
/// 3. One real test, which also proves the hotkey matches ChatGPT, then where
///    the app lives from now on.
///
/// Reopenable from the menu on purpose. Permissions get revoked and hotkeys get
/// changed, and "open setup and look at the ticks" is a better answer to a
/// broken install than a support thread.
///
/// The window floats: Hey Codex has no Dock icon, so a normal window disappears
/// behind whatever the user was doing the moment a permission dialog takes focus,
/// with no way back to it.
@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    enum Page: Int { case welcome, permissions, test }

    private let controller: AppController
    private let finished: () -> Void
    private var page: Page = .welcome
    private var poll: Timer?

    private let heading = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let progressLabel = NSTextField(labelWithString: "")

    /// Permission rows, built once and updated in place so the ticks can change
    /// while the user is looking at them.
    private let micRow = PermissionRow(title: "Microphone",
                                       reason: "So it can hear your phrase. Audio is processed here and never leaves your Mac.")
    private let axRow = PermissionRow(title: "Accessibility",
                                      reason: "So it can press the ChatGPT Voice hotkey on your behalf. That is all it does with this.")
    private let permissionsStack = NSStackView()
    /// The escape hatch. Granting Accessibility by adding the app in System
    /// Settings, rather than through the app's own prompt, does not always reach
    /// a process that is already running: `AXIsProcessTrusted` keeps saying no,
    /// so the automatic post-grant relaunch never triggers and setup has no way
    /// forward. A restart the user can press does not depend on macOS
    /// volunteering anything.
    private let restartButton = NSButton(title: "Already allowed it? Restart Hey Codex",
                                        target: nil, action: nil)

    /// The hotkey editor lives on the test page. Telling people to change
    /// ChatGPT to suit us is backwards: plenty already have a Voice hotkey they
    /// like, and Hey Codex is the side that should adapt.
    private let hotkeyStack = NSStackView()
    private let control = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let option = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let command = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let keyField = NSTextField(string: "V")

    /// The page a fresh window should open on. Reopening a finished setup from
    /// the menu must not march the user through the welcome text again.
    static func startingPage(for controller: AppController) -> Page {
        controller.setupState.isComplete ? .test : .welcome
    }

    init(controller: AppController, startAt page: Page = .welcome, finished: @escaping () -> Void) {
        self.controller = controller
        self.finished = finished
        self.page = page
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Hey Codex Setup"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        super.init(window: window)
        window.delegate = self
        buildView()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    // MARK: - Layout

    private func buildView() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 28, left: 30, bottom: 26, right: 30)

        progressLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        progressLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(progressLabel)

        heading.font = .systemFont(ofSize: 22, weight: .bold)
        heading.textColor = .labelColor
        root.addArrangedSubview(heading)

        body.font = .systemFont(ofSize: 13)
        body.textColor = .labelColor
        body.preferredMaxLayoutWidth = 490
        body.maximumNumberOfLines = 0
        root.addArrangedSubview(body)

        permissionsStack.orientation = .vertical
        permissionsStack.alignment = .leading
        permissionsStack.spacing = 12
        permissionsStack.addArrangedSubview(micRow.view)
        permissionsStack.addArrangedSubview(axRow.view)
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartToPickUpPermissions)
        permissionsStack.addArrangedSubview(restartButton)
        micRow.onAction = { [weak self] in self?.grantMicrophone() }
        axRow.onAction = { [weak self] in
            guard let self else { return }
            if self.controller.accessibilityGrantIsStale {
                self.controller.openVoiceShortcutSettings()
            } else {
                self.grantAccessibility()
            }
        }
        root.addArrangedSubview(permissionsStack)

        let keyLabel = NSTextField(labelWithString: "Key")
        keyLabel.font = .systemFont(ofSize: 13)
        keyField.alignment = .center
        keyField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        hotkeyStack.orientation = .horizontal
        hotkeyStack.spacing = 10
        hotkeyStack.alignment = .centerY
        for view in [control, option, command, keyLabel, keyField] {
            hotkeyStack.addArrangedSubview(view)
        }
        root.addArrangedSubview(hotkeyStack)

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .labelColor
        detail.preferredMaxLayoutWidth = 490
        detail.maximumNumberOfLines = 0
        root.addArrangedSubview(detail)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        root.addArrangedSubview(spacer)

        let buttons = NSStackView(views: [secondary, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        root.addArrangedSubview(buttons)

        window.contentView = root
    }

    // MARK: - Pages

    private func render() {
        switch page {
        case .welcome:     renderWelcome()
        case .permissions: renderPermissions()
        case .test:        renderTest()
        }
        window?.layoutIfNeeded()
    }


    /// Body copy with room to breathe. A plain wrapping label packs lines flush
    /// together, which turns a short list into a wall.
    private func setBody(_ text: String) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 9
        body.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    private func renderWelcome() {
        progressLabel.stringValue = "STEP 1 OF 3"
        heading.stringValue = "Welcome to Hey Codex"
        // Name the default phrase, not the enrolled one. This page also offers
        // "Hey Jarvis" as the example of a custom phrase, so interpolating a
        // user's own phrase here reads as a contradiction.
        setBody("""
            Say your launch phrase and Voice opens from anywhere.

            🎙  Listens for “Hey Codex” and nothing else
            🔒  Runs offline on this Mac. No recording, no uploads, no account
            ⌨️  Activates the same Voice hotkey you would press yourself
            ✨  Want a custom phrase like “Hey Jarvis” instead? Do it in Settings

            Just needs two permissions, setup in about a minute, and you are done.
            """)
        permissionsStack.isHidden = true
        hotkeyStack.isHidden = true
        detail.stringValue = ""
        primary.title = "Let's Go"
        primary.target = self
        primary.action = #selector(goToPermissions)
        primary.keyEquivalent = "\r"
        primary.isHidden = false
        secondary.title = "Later"
        secondary.target = self
        secondary.action = #selector(closeSetup)
        secondary.isHidden = false
    }

    private func renderPermissions() {
        progressLabel.stringValue = "STEP 2 OF 3"
        heading.stringValue = "Two quick permissions"
        setBody("""
            macOS will ask about each one separately. Grant them below and this page \
            ticks along with you, so there is nothing to come back and confirm.
            """)
        permissionsStack.isHidden = false
        hotkeyStack.isHidden = true
        refreshPermissionRows()
        primary.title = "Continue"
        primary.target = self
        primary.action = #selector(goToTest)
        primary.keyEquivalent = "\r"
        primary.isHidden = false
        primary.isEnabled = controller.setupState.isComplete
        restartButton.isHidden = controller.setupState.isComplete
        secondary.title = "Not Now"
        secondary.target = self
        secondary.action = #selector(closeSetup)
        secondary.isHidden = false
    }

    private func renderTest() {
        progressLabel.stringValue = "STEP 3 OF 3"
        heading.stringValue = "Match the Voice hotkey"
        permissionsStack.isHidden = true
        if !controller.isChatGPTInstalled {
            setBody("""
                Hey Codex works by pressing a hotkey inside the ChatGPT desktop app, and it \
                is not installed on this Mac yet. Grab it first and then come back here.
                """)
            hotkeyStack.isHidden = true
            detail.stringValue = ""
            primary.title = "Get ChatGPT for Mac"
            primary.target = self
            primary.action = #selector(openChatGPTDownload)
            primary.isEnabled = true
            secondary.title = "Done"
            secondary.target = self
            secondary.action = #selector(closeSetup)
            secondary.isHidden = false
            return
        }
        setBody("""
            Last thing: Hey Codex needs to know which hotkey opens Voice in ChatGPT, because \
            that is the key it presses for you.

            Check ChatGPT under Settings, then Voice. If it already shows a Voice chat hotkey, \
            set the same one below. If it is empty, set it to anything and match it here.
            """)
        hotkeyStack.isHidden = false
        loadHotkeyFields()
        detail.attributedStringValue = hint("""
            ✨  Want a different phrase?

            Use anything you like: “Hey Jarvis”, “Hey Computer”, your dog's name.
            From the menu bar icon, choose Use My Own Wake Phrase, say it three times, and it is yours.
            """, bold: ["Use My Own Wake Phrase"])
        primary.title = "Save and Test"
        primary.target = self
        primary.action = #selector(runTest)
        primary.keyEquivalent = "\r"
        primary.isEnabled = true
        primary.isHidden = false
        secondary.title = "Done"
        secondary.target = self
        secondary.action = #selector(closeSetup)
        secondary.isHidden = false
    }

    /// Restart so a fresh process reads the permissions macOS has recorded.
    @objc private func restartToPickUpPermissions() {
        controller.relaunch(reason: AppDelegate.accessibilityRelaunchArgument)
    }

    private func refreshPermissionRows() {
        micRow.setGranted(controller.isMicrophoneAuthorized,
                          actionTitle: controller.needsMicrophoneSettings ? "Open Settings" : "Allow")
        switch controller.setupState {
        case .ready:
            axRow.setGranted(true, actionTitle: "Allow")
        default:
            // Mid-grant, or not granted. Either way this is not done yet, and
            // showing a tick next to a disabled Continue button reads as a bug.
            // Once a relaunch has already been spent and it is still stuck -
            // whether the row is stale for this build or the grant never
            // landed at all - "Allow" cannot do anything further, so the
            // button sends them to the pane instead of pretending otherwise.
            axRow.setGranted(false, actionTitle: controller.accessibilityGrantIsStale ? "Open Settings" : "Allow")
        }
        primary.isEnabled = controller.setupState.isComplete
        restartButton.isHidden = controller.setupState.isComplete
        // Runs on every poll tick, not just when the page first renders, so the
        // guidance updates the moment the state does - e.g. the instant a
        // relaunch reveals the grant is stuck rather than only telling the
        // user that after they come back and look again.
        detail.stringValue = permissionsGuidance()
    }

    /// Names the permission actually blocking Continue and says why, in words
    /// that match what is on screen. A disabled Continue button with no
    /// explanation is how a first-time user ends up fighting the wrong
    /// permission for an hour.
    /// Short lines, and the reason. A paragraph of explanation on a page where
    /// someone is stuck reads as noise; they need to know which permission, what
    /// to click, and why macOS is behaving oddly.
    private func permissionsGuidance() -> String {
        switch controller.setupState {
        case .needsMicrophone:
            return """
                Microphone is blocking Continue.
                • Click Allow next to Microphone.
                • Accessibility comes after.
                """
        case .microphoneBlocked:
            return """
                Microphone is switched off, which blocks Continue.
                • Click Open Settings next to Microphone.
                • Turn Microphone on, then come back.
                """
        case .needsAccessibility, .accessibilityPendingRelaunch:
            if controller.accessibilityGrantIsStale {
                return """
                    Accessibility is blocking Continue, and macOS is ignoring the switch.
                    • Why: replacing the app, including by an update, makes macOS treat it as                     a new app. The old entry stays visible but no longer counts.
                    • Open Privacy & Security, Accessibility.
                    • Select Hey Codex, remove it with the minus button.
                    • Come back and click Allow.
                    """
            }
            return """
                Accessibility is blocking Continue.
                • Click Allow next to Accessibility.
                • Why nothing seems to happen: macOS shows no dialog for this one. It adds                 Hey Codex to Privacy & Security, Accessibility, switched off.
                • Turn that switch on. That is the actual permission.
                • This window restarts itself once it is on.
                """
        case .ready:
            return ""
        }
    }

    // MARK: - Polling

    private func startPolling() {
        poll?.invalidate()
        // The user is in System Settings, where the app is told nothing. Notice
        // the grant landing rather than making them find a re-check button.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.page == .permissions {
                    self.refreshPermissionRows()
                    if self.controller.setupState.isComplete {
                        self.page = .test
                        self.render()
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func goToPermissions() {
        page = .permissions
        render()
    }

    @objc private func goToTest() {
        page = .test
        render()
    }

    @objc private func grantMicrophone() {
        // Once refused, macOS never prompts again. Sending the user to the
        // Settings pane is the only route left.
        if controller.needsMicrophoneSettings {
            controller.openMicrophoneSettings()
            return
        }
        controller.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            if granted { self.controller.startListening() }
            // The system dialog took focus; take it back or the window is lost.
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.refreshPermissionRows()
        }
    }

    @objc private func grantAccessibility() {
        if controller.requestAccessibility() {
            refreshPermissionRows()
            return
        }
        controller.openVoiceShortcutSettings()
        refreshPermissionRows()
    }

    @objc private func openChatGPTDownload() {
        NSWorkspace.shared.open(URL(string: "https://openai.com/chatgpt/download/")!)
    }

    /// Builds hint text with menu item names set in bold. Without it a sentence
    /// like "Pick Use My Own Wake Phrase from the menu" gives the reader no way
    /// to tell where the instruction stops and the menu item starts.
    private func hint(_ text: String, bold: [String]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
        for phrase in bold {
            var range = (text as NSString).range(of: phrase)
            while range.location != NSNotFound {
                attributed.addAttribute(.font,
                                        value: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                        range: range)
                let next = NSRange(location: range.location + range.length,
                                   length: (text as NSString).length - range.location - range.length)
                range = (text as NSString).range(of: phrase, options: [], range: next)
            }
        }
        return attributed
    }

    private func loadHotkeyFields() {
        let shortcut = controller.settings.voiceShortcut
        control.state = shortcut.control ? .on : .off
        option.state = shortcut.option ? .on : .off
        command.state = shortcut.command ? .on : .off
        keyField.stringValue = shortcut.key.uppercased()
    }

    @objc private func runTest() {
        // Save what is on screen first, so the test always exercises the hotkey
        // the user just told us about rather than a stale one.
        do {
            try controller.updateShortcut(key: keyField.stringValue,
                                         control: control.state == .on,
                                         option: option.state == .on,
                                         command: command.state == .on)
        } catch {
            heading.stringValue = "That hotkey will not work"
            body.stringValue = error.localizedDescription
            return
        }
        primary.isEnabled = false
        primary.title = controller.isChatGPTRunning ? "Testing…" : "Starting ChatGPT…"
        controller.testVoiceShortcut { [weak self] result in
            guard let self else { return }
            self.primary.isEnabled = true
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            switch result {
            case .success:
                self.heading.stringValue = "You're all set 🎉"
                self.setBody("""
                    ChatGPT Voice should have just opened. Now try it for real: say \
                    “\(self.controller.settings.wakePhrase)” out loud from any app.

                    🔍  Look for the small icon in your menu bar. That is home now.
                    ✨  Change your phrase, tune sensitivity, or re-test from there.
                    🙌  That is everything. Go talk to it.
                    """)
                self.detail.attributedStringValue = self.hint("""
                    Nothing opened? Then ChatGPT's Voice chat hotkey is not \(self.controller.settings.voiceShortcut.displayString) after all.

                    Check it in ChatGPT under Settings, then Voice. Correct it above and test again.
                    """, bold: ["Settings", "Voice"])
                self.primary.title = "Test Again"
                self.hotkeyStack.isHidden = false
                self.secondary.title = "Done"
                self.secondary.keyEquivalent = "\r"
            case .failure(let error):
                self.heading.stringValue = "That did not go through"
                self.body.stringValue = error.localizedDescription
                self.primary.title = "Try Again"
            }
        }
    }

    @objc private func closeSetup() { close() }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        finished()
    }

    /// A permission with a visible state, so a granted one reads as done and a
    /// revoked one is obvious when the window is reopened later.
    @MainActor
    final class PermissionRow {
        let view = NSStackView()
        var onAction: (() -> Void)?
        private let mark = NSTextField(labelWithString: "")
        private let button = NSButton(title: "Allow", target: nil, action: nil)
        private let titleLabel: NSTextField

        init(title: String, reason: String) {
            titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            let reasonLabel = NSTextField(wrappingLabelWithString: reason)
            reasonLabel.font = .systemFont(ofSize: 11)
            reasonLabel.textColor = .secondaryLabelColor
            reasonLabel.preferredMaxLayoutWidth = 330
            reasonLabel.maximumNumberOfLines = 0

            mark.font = .systemFont(ofSize: 17, weight: .bold)
            mark.widthAnchor.constraint(equalToConstant: 22).isActive = true

            let text = NSStackView(views: [titleLabel, reasonLabel])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.widthAnchor.constraint(equalToConstant: 340).isActive = true

            button.target = self
            button.action = #selector(tapped)

            view.orientation = .horizontal
            view.alignment = .centerY
            view.spacing = 12
            view.addArrangedSubview(mark)
            view.addArrangedSubview(text)
            view.addArrangedSubview(button)
        }

        @objc private func tapped() { onAction?() }

        func setGranted(_ granted: Bool, actionTitle: String = "Allow") {
            button.title = actionTitle
            mark.stringValue = granted ? "✓" : "○"
            mark.textColor = granted ? .systemGreen : .secondaryLabelColor
            button.isHidden = granted
            button.isEnabled = !granted
        }
    }
}
