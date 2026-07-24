import AppKit

/// The only window shown automatically. It owns the two consent steps in the
/// order people encounter them: microphone first, then the narrowly scoped
/// permission that lets Hey Codex send the configured ChatGPT Voice shortcut.
@MainActor
final class FirstRunSetupWindowController: NSWindowController, NSWindowDelegate {
    private let controller: AppController
    private let finished: () -> Void
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton(title: "", target: nil, action: nil)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let done = NSButton(title: "Not now", target: nil, action: nil)

    init(controller: AppController, finished: @escaping () -> Void) {
        self.controller = controller
        self.finished = finished
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 310),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set up Hey Codex"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildView()
        showCurrentStep()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showWindowOnTop() {
        showCurrentStep()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        root.addArrangedSubview(headline)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 13)
        detail.maximumNumberOfLines = 0
        detail.widthAnchor.constraint(equalToConstant: 430).isActive = true
        root.addArrangedSubview(detail)

        let buttons = NSStackView(views: [primary, secondary, done])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        root.addArrangedSubview(buttons)
        done.target = self
        done.action = #selector(closeSetup)
    }

    private func showCurrentStep() {
        if !controller.isMicrophoneAuthorized {
            controller.needsMicrophoneSettings ? showMicrophoneSettingsStep() : showMicrophoneStep()
        } else {
            if controller.refreshVoiceShortcutPermission() {
                showVoiceReadyStep()
            } else {
                showVoiceStep()
            }
        }
    }

    private func showMicrophoneStep() {
        headline.stringValue = "Allow microphone access"
        detail.stringValue = "Hey Codex listens locally for your wake phrase. Audio and wake-word processing stay on this Mac."
        primary.title = "Allow Microphone"
        primary.target = self
        primary.action = #selector(requestMicrophone)
        primary.isHidden = false
        secondary.isHidden = true
        done.title = "Not now"
    }

    private func showMicrophoneSettingsStep() {
        headline.stringValue = "Enable microphone access in Settings"
        detail.stringValue = "macOS has not allowed Hey Codex to use the microphone yet. Enable it in Privacy & Security → Microphone, then return here."
        primary.title = "Open Microphone Settings"
        primary.target = self
        primary.action = #selector(openMicrophoneSettings)
        primary.isHidden = false
        secondary.title = "I enabled it - Check again"
        secondary.target = self
        secondary.action = #selector(showCurrentStepFromUserAction)
        secondary.isHidden = false
        done.title = "Not now"
        done.isHidden = false
    }

    private func showVoiceStep() {
        headline.stringValue = "Enable ChatGPT Voice"
        detail.stringValue = "In ChatGPT: Settings → Voice, set the Voice chat hotkey to \(controller.settings.voiceShortcut.displayString). Hey Codex presses that same hotkey for you when it hears “Hey Codex,” so the two must match."
        primary.title = "Enable ChatGPT Voice"
        primary.target = self
        primary.action = #selector(requestVoicePermission)
        primary.isHidden = false
        secondary.isHidden = true
        done.title = "Not now"
        done.isHidden = false
    }

    private func showVoiceReadyStep() {
        headline.stringValue = "ChatGPT Voice is enabled"
        detail.stringValue = "Run one quick check now. It sends your configured shortcut exactly as Hey Codex will after a wake phrase."
        primary.title = "Test ChatGPT Voice"
        primary.target = self
        primary.action = #selector(testVoiceShortcut)
        primary.isHidden = false
        secondary.title = "Done"
        secondary.target = self
        secondary.action = #selector(closeSetup)
        secondary.isHidden = false
        done.isHidden = true
    }

    @objc private func requestMicrophone() {
        primary.isEnabled = false
        controller.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            self.primary.isEnabled = true
            if granted {
                self.controller.startListening()
                self.showVoiceStep()
            } else {
                self.headline.stringValue = "Microphone access is required"
                self.detail.stringValue = "Enable Hey Codex in System Settings → Privacy & Security → Microphone, then return here."
                self.primary.title = "Open Microphone Settings"
                self.primary.action = #selector(self.openMicrophoneSettings)
            }
        }
    }

    @objc private func requestVoicePermission() {
        if controller.requestVoiceShortcutPermission() {
            showVoiceReadyStep()
        } else {
            headline.stringValue = "Allow shortcut control in Accessibility"
            detail.stringValue = "macOS displays this narrow keyboard-event permission in Accessibility. Enable Hey Codex there, return here, and try again."
            primary.title = "Open Accessibility Settings"
            primary.action = #selector(openVoiceSettings)
            secondary.title = "I enabled it - Check again"
            secondary.target = self
            secondary.action = #selector(requestVoicePermission)
            secondary.isHidden = false
            done.title = "Not now"
            done.isHidden = false
        }
    }

    @objc private func testVoiceShortcut() {
        primary.isEnabled = false
        controller.testVoiceShortcut { [weak self] result in
            guard let self else { return }
            self.primary.isEnabled = true
            switch result {
            case .success:
                self.detail.stringValue = "Shortcut sent. If ChatGPT Voice opened, you are all set - choose Done. If nothing happened, the hotkey in ChatGPT does not match \(self.controller.settings.voiceShortcut.displayString)."
                self.primary.isHidden = true
                self.secondary.title = "Done"
                self.secondary.target = self
                self.secondary.action = #selector(self.closeSetup)
                self.secondary.isHidden = false
                self.done.isHidden = true
            case .failure(let error):
                self.headline.stringValue = "ChatGPT Voice test could not run"
                self.detail.stringValue = error.localizedDescription
                self.primary.title = "Try again"
                self.primary.isHidden = false
                self.secondary.isHidden = true
                self.done.title = "Not now"
                self.done.isHidden = false
            }
        }
    }

    @objc private func openMicrophoneSettings() { controller.openMicrophoneSettings() }
    @objc private func openVoiceSettings() { controller.openVoiceShortcutSettings() }
    @objc private func showCurrentStepFromUserAction() { showCurrentStep() }
    @objc private func closeSetup() { close() }
    func windowDidBecomeKey(_ notification: Notification) { showCurrentStep() }
    func windowWillClose(_ notification: Notification) { finished() }
}
