import AppKit
import HeyClaudeKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let controller: AppController
    private let shortcutKey = NSTextField(string: "v")
    private let control = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let option = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let command = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let sensitivity = NSPopUpButton(frame: .zero, pullsDown: false)
    private let notice = NSTextField(labelWithString: "")

    init(controller: AppController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Hey Codex Settings"
        window.center()
        super.init(window: window)
        buildView()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildView() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 15
        root.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 26, right: 28)
        window.contentView = root

        root.addArrangedSubview(title("Hey Codex"))
        root.addArrangedSubview(label("A local wake-word helper for ChatGPT desktop Voice."))
        root.addArrangedSubview(rule())

        root.addArrangedSubview(title("Wake sensitivity"))
        sensitivity.addItems(withTitles: ["Balanced", "More sensitive", "Maximum sensitivity"])
        sensitivity.target = self
        sensitivity.action = #selector(saveSensitivity)
        root.addArrangedSubview(sensitivity)
        let sensitivityHint = label("More sensitive catches a quieter normal voice more readily. Maximum sensitivity can increase accidental wakes. This local alpha listens only for Hey Codex.")
        sensitivityHint.maximumNumberOfLines = 0
        root.addArrangedSubview(sensitivityHint)
        root.addArrangedSubview(rule())
        root.addArrangedSubview(title("ChatGPT Voice shortcut"))
        let shortcut = NSStackView(views: [control, option, command, label("Key:"), shortcutKey])
        shortcut.orientation = .horizontal
        shortcut.spacing = 8
        shortcutKey.alignment = .center
        shortcutKey.maximumNumberOfLines = 1
        shortcutKey.widthAnchor.constraint(equalToConstant: 34).isActive = true
        root.addArrangedSubview(shortcut)
        let save = NSButton(title: "Save shortcut", target: self, action: #selector(saveShortcut))
        root.addArrangedSubview(save)
        let shortcutHint = label("Set this exact global shortcut in ChatGPT desktop’s Voice settings. Default: ⌃⌥V — never Command-V.")
        shortcutHint.maximumNumberOfLines = 0
        root.addArrangedSubview(shortcutHint)

        root.addArrangedSubview(rule())
        let permissions = label("Required: Microphone for local listening, and permission to send the configured global shortcut. Hey Codex requests both in its first-run setup, then keeps the setup controls out of the everyday menu. Audio and wake-word processing stay on this Mac.")
        permissions.maximumNumberOfLines = 0
        root.addArrangedSubview(permissions)
        notice.textColor = .systemRed
        notice.maximumNumberOfLines = 0
        root.addArrangedSubview(notice)
    }

    private func reload() {
        let shortcut = controller.settings.voiceShortcut
        shortcutKey.stringValue = shortcut.key
        control.state = shortcut.control ? .on : .off
        option.state = shortcut.option ? .on : .off
        command.state = shortcut.command ? .on : .off
        sensitivity.selectItem(at: sensitivityIndex(for: controller.settings.wakeKeywordsThreshold))
        notice.stringValue = ""
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
            notice.stringValue = "Saved. Configure the same chord in ChatGPT desktop Voice settings."
        } catch { show(error.localizedDescription) }
    }

    private func show(_ text: String) {
        notice.textColor = .systemRed
        notice.stringValue = text
    }

    private func title(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        return field
    }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 13)
        return field
    }

    private func rule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return box
    }
}
