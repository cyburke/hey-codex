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
                                       reason: "So it can hear your wake phrase. Audio never leaves this Mac.")
    private let axRow = PermissionRow(title: "Accessibility",
                                      reason: "So it can press the ChatGPT Voice hotkey for you.")
    private let permissionsStack = NSStackView()

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
        micRow.onAction = { [weak self] in self?.grantMicrophone() }
        axRow.onAction = { [weak self] in self?.grantAccessibility() }
        root.addArrangedSubview(permissionsStack)

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

    private func renderWelcome() {
        progressLabel.stringValue = "STEP 1 OF 3"
        heading.stringValue = "Hey Codex"
        body.stringValue = """
            Say it. Voice opens. That is the whole tool.

            🎙  Listens for “\(controller.settings.wakePhrase)” and nothing else
            🔒  Runs offline on this Mac. No recording, no uploads, no account
            ⌨️  Presses the same Voice hotkey you would press yourself
            ✨  Want “Hey Jarvis” instead? You can record your own later

            Two permissions, about a minute, and you are done.
            """
        permissionsStack.isHidden = true
        detail.stringValue = ""
        primary.title = "Get Started"
        primary.target = self
        primary.action = #selector(goToPermissions)
        primary.keyEquivalent = "\r"
        primary.isHidden = false
        secondary.title = "Not Now"
        secondary.target = self
        secondary.action = #selector(closeSetup)
        secondary.isHidden = false
    }

    private func renderPermissions() {
        progressLabel.stringValue = "STEP 2 OF 3"
        heading.stringValue = "Two permissions"
        body.stringValue = "macOS asks for each one separately. This page updates itself as you grant them."
        permissionsStack.isHidden = false
        refreshPermissionRows()
        detail.stringValue = "After you allow Accessibility, Hey Codex restarts itself so macOS hands over the permission. That is expected, and this window comes back."
        primary.title = "Continue"
        primary.target = self
        primary.action = #selector(goToTest)
        primary.keyEquivalent = "\r"
        primary.isHidden = false
        primary.isEnabled = controller.setupState.isComplete
        secondary.title = "Not Now"
        secondary.target = self
        secondary.action = #selector(closeSetup)
        secondary.isHidden = false
    }

    private func renderTest() {
        progressLabel.stringValue = "STEP 3 OF 3"
        heading.stringValue = "Check it works"
        permissionsStack.isHidden = true
        if !controller.isChatGPTInstalled {
            body.stringValue = "The ChatGPT desktop app is not installed. Hey Codex presses a hotkey inside it, so it needs to be there first."
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
        body.stringValue = """
            One quick check and you are finished.

            1.  In ChatGPT, open Settings then Voice
            2.  Set the Voice chat hotkey to \(controller.settings.voiceShortcut.displayString)
            3.  Press the button below

            Hey Codex presses exactly that hotkey, so the two have to match.
            """
        detail.stringValue = "✨  Not a fan of “Hey Codex”? Pick Use My Own Wake Phrase from the menu bar, say “Hey Jarvis” three times, and that becomes your phrase."
        primary.title = "Test ChatGPT Voice"
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

    private func refreshPermissionRows() {
        micRow.setGranted(controller.isMicrophoneAuthorized,
                          actionTitle: controller.needsMicrophoneSettings ? "Open Settings" : "Allow")
        switch controller.setupState {
        case .ready, .accessibilityPendingRelaunch:
            axRow.setGranted(true, actionTitle: "Allow")
        default:
            axRow.setGranted(false, actionTitle: "Allow")
        }
        primary.isEnabled = controller.setupState.isComplete
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

    @objc private func runTest() {
        primary.isEnabled = false
        primary.title = controller.isChatGPTRunning ? "Testing…" : "Starting ChatGPT…"
        controller.testVoiceShortcut { [weak self] result in
            guard let self else { return }
            self.primary.isEnabled = true
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            switch result {
            case .success:
                self.heading.stringValue = "You are all set"
                self.body.stringValue = """
                    Voice should have just opened. Try it for real: say \
                    “\(self.controller.settings.wakePhrase)” from any app.

                    🔍  Everything lives in the menu bar icon from now on
                    ✨  Change the phrase, tune sensitivity, or re-test from there
                    """
                self.detail.stringValue = "Nothing opened? The hotkey in ChatGPT does not match \(self.controller.settings.voiceShortcut.displayString). Fix it there and test again."
                self.primary.title = "Test Again"
                self.secondary.title = "Done"
                self.secondary.keyEquivalent = "\r"
            case .failure(let error):
                self.heading.stringValue = "That test could not run"
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
