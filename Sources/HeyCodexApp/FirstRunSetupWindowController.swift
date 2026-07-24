import AppKit

/// The only window shown automatically. It walks the two consent steps in the
/// order people meet them: microphone first, then the narrowly scoped permission
/// that lets Hey Codex press the ChatGPT Voice shortcut.
///
/// Three things this has to survive, all learned the hard way:
///
/// 1. Hey Codex has no Dock icon, so a normal-level window vanishes behind
///    everything else the moment a system dialog takes focus, with no way to
///    click back to it. The window floats.
/// 2. `CGPreflightPostEventAccess` caches its answer for the life of the
///    process. Once it says no, it says no forever, however many times the user
///    grants Accessibility. Detecting that is what the relaunch offer is for.
/// 3. The user leaves for System Settings and comes back. Progress has to be
///    picked up automatically and must never move backwards.
@MainActor
final class FirstRunSetupWindowController: NSWindowController, NSWindowDelegate {
    private enum Step: Int, Comparable {
        case microphone, microphoneSettings, accessibility, test
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    private let controller: AppController
    private let finished: () -> Void
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let done = NSButton(title: "Not now", target: nil, action: nil)

    private var step: Step = .microphone
    private var poll: Timer?
    /// Set once the user has been sent to Accessibility. Only then is a stuck
    /// permission check worth explaining, rather than pre-emptive noise.
    private var visitedAccessibilitySettings = false

    init(controller: AppController, finished: @escaping () -> Void) {
        self.controller = controller
        self.finished = finished
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set up Hey Codex"
        window.isReleasedWhenClosed = false
        // No Dock icon means a normal window is unrecoverable once it goes
        // behind. Floating keeps it reachable across the permission dialogs.
        window.level = .floating
        window.center()
        super.init(window: window)
        window.delegate = self
        buildView()
        step = firstIncompleteStep()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showWindowOnTop() {
        advance()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    private func buildView() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 30, left: 30, bottom: 28, right: 30)
        window.contentView = root

        let title = NSTextField(labelWithString: "Hey Codex")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        root.addArrangedSubview(title)
        headline.font = .systemFont(ofSize: 17, weight: .semibold)
        headline.textColor = .labelColor
        root.addArrangedSubview(headline)
        detail.textColor = .labelColor
        detail.font = .systemFont(ofSize: 13)
        detail.maximumNumberOfLines = 0
        detail.widthAnchor.constraint(equalToConstant: 450).isActive = true
        root.addArrangedSubview(detail)

        let buttons = NSStackView(views: [primary, secondary, done])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        root.addArrangedSubview(buttons)
        done.target = self
        done.action = #selector(closeSetup)
    }

    // MARK: - Step machine

    private func firstIncompleteStep() -> Step {
        if !controller.isMicrophoneAuthorized {
            return controller.needsMicrophoneSettings ? .microphoneSettings : .microphone
        }
        return controller.refreshVoiceShortcutPermission() ? .test : .accessibility
    }

    /// Move forward if the current requirement is now satisfied. Never moves
    /// back: a granted permission that macOS briefly misreports must not throw
    /// the user out of a later step.
    private func advance() {
        let target = firstIncompleteStep()
        guard target > step else { return }
        step = target
        render()
    }

    private func startPolling() {
        poll?.invalidate()
        // The user is in System Settings, not here. Notice the grant and move on
        // without making them find a button to prove it.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    private func render() {
        switch step {
        case .microphone:      renderMicrophone()
        case .microphoneSettings: renderMicrophoneSettings()
        case .accessibility:   renderAccessibility()
        case .test:            renderTest()
        }
    }

    // MARK: - Steps

    private func renderMicrophone() {
        headline.stringValue = "Step 1 of 2: allow the microphone"
        detail.stringValue = "Hey Codex listens on this Mac for your wake phrase. Nothing is recorded and no audio ever leaves the machine."
        primary.title = "Allow Microphone"
        primary.target = self
        primary.action = #selector(requestMicrophone)
        primary.isHidden = false
        primary.keyEquivalent = "\r"
        secondary.isHidden = true
        done.title = "Not now"
        done.isHidden = false
    }

    private func renderMicrophoneSettings() {
        headline.stringValue = "Step 1 of 2: allow the microphone"
        detail.stringValue = "macOS is blocking microphone access. Turn on Hey Codex under Privacy & Security, Microphone. This window updates by itself once you do."
        primary.title = "Open Microphone Settings"
        primary.target = self
        primary.action = #selector(openMicrophoneSettings)
        primary.isHidden = false
        primary.keyEquivalent = "\r"
        secondary.isHidden = true
        done.title = "Not now"
        done.isHidden = false
    }

    private func renderAccessibility() {
        headline.stringValue = "Step 2 of 2: allow Hey Codex to press the hotkey"
        detail.stringValue = "macOS lists this permission under Accessibility. Turn on Hey Codex there and this window will continue on its own."
        primary.title = visitedAccessibilitySettings ? "Open Accessibility Settings Again" : "Open Accessibility Settings"
        primary.target = self
        primary.action = #selector(openAccessibilitySettings)
        primary.isHidden = false
        primary.keyEquivalent = "\r"
        // macOS hands a process its Accessibility answer once and never revises
        // it, so a relaunch is the only honest way out of a stale "no".
        secondary.title = "Already allowed it? Relaunch Hey Codex"
        secondary.target = self
        secondary.action = #selector(relaunch)
        secondary.isHidden = !visitedAccessibilitySettings
        done.title = "Not now"
        done.isHidden = false
    }

    private func renderTest() {
        headline.stringValue = "You are set up"
        detail.stringValue = "Say “\(controller.settings.wakePhrase)” and ChatGPT Voice opens. Run one test now if you want to be sure the hotkey matches."
        primary.title = "Test ChatGPT Voice"
        primary.target = self
        primary.action = #selector(testVoiceShortcut)
        primary.isHidden = false
        primary.keyEquivalent = ""
        secondary.title = "Done"
        secondary.target = self
        secondary.action = #selector(closeSetup)
        secondary.isHidden = false
        secondary.keyEquivalent = "\r"
        done.isHidden = true
    }

    // MARK: - Actions

    @objc private func requestMicrophone() {
        primary.isEnabled = false
        controller.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            self.primary.isEnabled = true
            // The system dialog stole focus. Take it back, or the window is gone
            // behind whatever the user was doing.
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            if granted { self.controller.startListening() }
            self.step = self.firstIncompleteStep()
            self.render()
        }
    }

    @objc private func openMicrophoneSettings() { controller.openMicrophoneSettings() }

    @objc private func openAccessibilitySettings() {
        // Ask the system first: on a fresh install this shows the standard
        // prompt and can be granted without leaving the app at all.
        if controller.requestVoiceShortcutPermission() {
            step = .test
            render()
            return
        }
        visitedAccessibilitySettings = true
        controller.openVoiceShortcutSettings()
        render()
    }

    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    @objc private func testVoiceShortcut() {
        primary.isEnabled = false
        controller.testVoiceShortcut { [weak self] result in
            guard let self else { return }
            self.primary.isEnabled = true
            switch result {
            case .success:
                self.detail.stringValue = "Shortcut sent. If ChatGPT Voice opened you are all set. If nothing happened, the hotkey in ChatGPT does not match \(self.controller.settings.voiceShortcut.displayString)."
                self.primary.isHidden = true
            case .failure(let error):
                self.headline.stringValue = "That test could not run"
                self.detail.stringValue = error.localizedDescription
                self.primary.title = "Try Again"
                self.primary.isHidden = false
            }
        }
    }

    @objc private func closeSetup() { close() }

    func windowDidBecomeKey(_ notification: Notification) { advance() }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        finished()
    }
}
