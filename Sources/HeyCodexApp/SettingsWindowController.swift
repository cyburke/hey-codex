import AppKit
import HeyCodexKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let controller: AppController
    private let shortcutKey = NSTextField(string: "v")
    private let control = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let option = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let command = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let sensitivity = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoUpdates = NSButton(checkboxWithTitle: "Check for updates automatically",
                                       target: nil, action: nil)
    private let inputDevice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let inputHint = NSTextField(wrappingLabelWithString: "")
    /// Menu index to device UID. Index 0 is Automatic, which has no UID.
    private var inputDeviceUIDs: [String?] = [nil]
    private let notice = NSTextField(labelWithString: "")
    private let phraseValue = NSTextField(labelWithString: "")
    /// Set by AppDelegate so Settings opens the same enrollment window the menu
    /// does, rather than a second competing instance.
    var onChangeWakePhrase: (() -> Void)?

    init(controller: AppController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Hey Codex Settings"
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        buildView()
        reload()
        // Size to the content instead of a hardcoded height: the sections wrap
        // to the user's text size, and a fixed frame clips the last one.
        if let root = window.contentView {
            window.layoutIfNeeded()
            window.setContentSize(NSSize(width: 540, height: ceil(root.fittingSize.height)))
        }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildView() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)
        window.contentView = root

        // Wake phrase ------------------------------------------------------
        root.addArrangedSubview(sectionHeader("Your wake phrase"))
        phraseValue.font = .systemFont(ofSize: 15, weight: .medium)
        let phraseRow = NSStackView(views: [phraseValue,
                                            NSButton(title: "Change…", target: self,
                                                     action: #selector(changeWakePhrase))])
        phraseRow.orientation = .horizontal
        phraseRow.spacing = 12
        root.addArrangedSubview(phraseRow)
        root.addArrangedSubview(hint("Use anything you like. “Hey Jarvis”, “Hey Computer”, or something only you would say. Two or three words works best."))

        root.addArrangedSubview(rule())

        // Microphone -------------------------------------------------------
        root.addArrangedSubview(sectionHeader("Microphone"))
        inputDevice.target = self
        inputDevice.action = #selector(saveInputDevice)
        root.addArrangedSubview(inputDevice)
        inputHint.font = .systemFont(ofSize: 11)
        inputHint.textColor = .secondaryLabelColor
        inputHint.preferredMaxLayoutWidth = 470
        inputHint.maximumNumberOfLines = 0
        root.addArrangedSubview(inputHint)

        root.addArrangedSubview(rule())

        // Shortcut ---------------------------------------------------------
        root.addArrangedSubview(sectionHeader("ChatGPT Voice hotkey"))
        root.addArrangedSubview(body("Hey Codex presses this for you, so it has to match the Voice chat hotkey set in ChatGPT. Change it in both places or neither."))
        // Modifiers and the key live on separate rows. Inline, the "Command"
        // checkbox sat flush against the "Key" field label and the row read as
        // "Command Key" - a misparse this window can least afford.
        let modifiers = NSStackView(views: [control, option, command])
        modifiers.orientation = .horizontal
        modifiers.spacing = 14
        root.addArrangedSubview(modifiers)

        let keyLabel = NSTextField(labelWithString: "Key")
        keyLabel.font = .systemFont(ofSize: 13)
        keyLabel.textColor = .labelColor
        shortcutKey.alignment = .center
        shortcutKey.maximumNumberOfLines = 1
        shortcutKey.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let saveShortcutButton = NSButton(title: "Save", target: self, action: #selector(saveShortcut))
        let keyRow = NSStackView(views: [keyLabel, shortcutKey, saveShortcutButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyRow.setCustomSpacing(18, after: shortcutKey)
        root.addArrangedSubview(keyRow)

        root.addArrangedSubview(rule())

        // Sensitivity ------------------------------------------------------
        root.addArrangedSubview(sectionHeader("Wake sensitivity"))
        sensitivity.addItems(withTitles: ["Balanced", "More sensitive", "Maximum sensitivity"])
        sensitivity.target = self
        sensitivity.action = #selector(saveSensitivity)
        root.addArrangedSubview(sensitivity)
        root.addArrangedSubview(hint("Higher sensitivity picks up a quieter voice, at the cost of the occasional false start. Balanced suits most people."))

        root.addArrangedSubview(rule())

        // Updates ----------------------------------------------------------
        root.addArrangedSubview(sectionHeader("Updates"))
        autoUpdates.target = self
        autoUpdates.action = #selector(saveAutoUpdates)
        root.addArrangedSubview(autoUpdates)
        root.addArrangedSubview(hint("Once a day, Hey Codex asks GitHub whether there is a newer version. That is the only network request it ever makes, and switching this off means it makes none at all."))

        root.addArrangedSubview(rule())

        // Privacy ----------------------------------------------------------
        root.addArrangedSubview(sectionHeader("Privacy"))
        root.addArrangedSubview(body("Everything you say is processed here on your Mac. Nothing is recorded, nothing is stored, and nothing is sent anywhere."))
        root.addArrangedSubview(hint("It uses the microphone to hear your phrase and Accessibility to press the hotkey. That is the whole list."))

        notice.font = .systemFont(ofSize: 12, weight: .medium)
        notice.maximumNumberOfLines = 0
        root.addArrangedSubview(notice)
    }

    private func reload() {
        let shortcut = controller.settings.voiceShortcut
        shortcutKey.stringValue = shortcut.key.uppercased()
        control.state = shortcut.control ? .on : .off
        option.state = shortcut.option ? .on : .off
        command.state = shortcut.command ? .on : .off
        sensitivity.selectItem(at: sensitivityIndex(for: controller.settings.wakeKeywordsThreshold))
        phraseValue.stringValue = "“\(controller.settings.wakePhrase)”"
        autoUpdates.state = controller.settings.automaticUpdateChecks ? .on : .off
        reloadInputDevices()
        notice.stringValue = ""
    }

    @objc private func changeWakePhrase() { onChangeWakePhrase?() }

    /// Rebuilt every time the window opens, because microphones come and go.
    private func reloadInputDevices() {
        let devices = controller.availableInputDevices
        inputDevice.removeAllItems()
        inputDeviceUIDs = [nil]
        inputDevice.addItem(withTitle: "Automatic (follow system setting)")
        for device in devices {
            inputDevice.addItem(withTitle: device.name)
            inputDeviceUIDs.append(device.uid)
        }
        let chosen = controller.settings.inputDeviceUID
        if let chosen, let index = inputDeviceUIDs.firstIndex(of: chosen) {
            inputDevice.selectItem(at: index)
        } else if let chosen {
            // Saved but not plugged in. Keep it listed and selected rather than
            // silently rewriting the preference, so reconnecting just works.
            inputDevice.addItem(withTitle: "Not connected")
            inputDeviceUIDs.append(chosen)
            inputDevice.selectItem(at: inputDeviceUIDs.count - 1)
        } else {
            inputDevice.selectItem(at: 0)
        }

        if devices.isEmpty {
            inputHint.stringValue = "No microphone is connected. Hey Codex cannot hear anything until one is."
        } else if controller.chosenInputUnavailable {
            inputHint.stringValue = "That microphone is not connected right now, so Hey Codex is listening on \(controller.activeInputName ?? "another device"). It will switch back when you plug it in again."
        } else if let active = controller.activeInputName {
            inputHint.stringValue = "Listening on \(active). Bluetooth headsets and USB mics show up here once connected."
        } else {
            inputHint.stringValue = "Bluetooth headsets and USB microphones appear here once they are connected."
        }
    }

    @objc private func saveInputDevice() {
        let index = inputDevice.indexOfSelectedItem
        guard index >= 0, index < inputDeviceUIDs.count else { return }
        do {
            try controller.selectInputDevice(uid: inputDeviceUIDs[index])
            notice.textColor = .systemGreen
            notice.stringValue = "Saved. Listening restarted on \(controller.activeInputName ?? "the new microphone")."
            reloadInputDevices()
        } catch { show(error.localizedDescription) }
    }

    @objc private func saveAutoUpdates() {
        do {
            try controller.setAutomaticUpdateChecks(autoUpdates.state == .on)
            notice.textColor = .systemGreen
            notice.stringValue = autoUpdates.state == .on
                ? "Saved. Hey Codex will check for new versions once a day."
                : "Saved. Update checks are off, so Hey Codex will not touch the network at all."
        } catch { show(error.localizedDescription) }
    }

    private func sensitivityIndex(for threshold: Float) -> Int {
        if threshold <= 0.10 { return 2 }
        if threshold <= 0.18 { return 1 }
        return 0
    }

    @objc private func saveSensitivity() {
        let threshold: Float
        switch sensitivity.indexOfSelectedItem {
        case 0: threshold = 0.25
        case 1: threshold = 0.15
        default: threshold = 0.08
        }
        do {
            try controller.updateWakeSensitivity(threshold: threshold)
            notice.textColor = .systemGreen
            notice.stringValue = "Saved. Listening restarted with the new sensitivity."
        } catch { show(error.localizedDescription) }
    }

    @objc private func saveShortcut() {
        do {
            try controller.updateShortcut(key: shortcutKey.stringValue,
                                          control: control.state == .on,
                                          option: option.state == .on,
                                          command: command.state == .on)
            notice.textColor = .systemGreen
            notice.stringValue = "Saved. Remember to set the same combination in ChatGPT under Settings, then Voice."
        } catch { show(error.localizedDescription) }
    }

    private func show(_ text: String) {
        notice.textColor = .systemRed
        notice.stringValue = text
    }

    /// Section heading. Primary colour - headings must never be gray.
    private func sectionHeader(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = .labelColor
        return field
    }

    /// Explanatory copy the user is expected to read. Full-contrast primary
    /// colour: anything worth writing is worth making legible.
    private func body(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.preferredMaxLayoutWidth = 470
        field.maximumNumberOfLines = 0
        return field
    }

    /// Genuinely secondary asides only - short, skippable, and never carrying
    /// information the user needs to complete a task.
    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 470
        field.maximumNumberOfLines = 0
        return field
    }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    /// A separator in a vertical NSStackView needs BOTH dimensions pinned - with
    /// no height constraint it lays out at zero and never appears.
    private func rule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 484).isActive = true
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}
