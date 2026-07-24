import AppKit
import Foundation

/// Executes a resolved Command. Side effects are injected so it's testable
/// (mock launcher, runShell, openURL) and the real defaults live in one place.
///
/// `execute` reports its outcome through a `completion` closure rather than a
/// synchronous `throws`: launch failures arrive on two clocks — terminal/editor
/// failures are synchronous, but deep-link success is best-effort. One `Result`
/// channel captures both. The typed `LaunchFailure` crosses to the caller intact
/// (it's `Sendable`) so the UI can show a specific, actionable message — never a
/// bare `Bool`.
public struct CommandExecutor: Sendable {
    private let settings: Settings
    private let launcherFor: @Sendable (TerminalKind) -> TerminalLauncher
    private let runShell: @Sendable (String) throws -> Void
    private let openURL: @Sendable (URL) -> Bool

    public init(settings: Settings,
                launcherFor: @escaping @Sendable (TerminalKind) -> TerminalLauncher,
                runShell: @escaping @Sendable (String) throws -> Void = CommandExecutor.defaultRunShell,
                openURL: @escaping @Sendable (URL) -> Bool = CommandExecutor.defaultOpenURL) {
        self.settings = settings
        self.launcherFor = launcherFor
        self.runShell = runShell
        self.openURL = openURL
    }

    /// Runs the command and reports success or a typed failure via `completion`.
    /// All paths call `completion` inline (synchronous).
    public func execute(_ command: Command, prompt: String?,
                        completion: @escaping @Sendable (Result<Void, LaunchFailure>) -> Void) {
        switch command.kind {
        case .runCLI(let template):
            let prompt = command.acceptsPrompt ? prompt : nil
            let target = command.target ?? settings.preferredTarget
            switch target {
            case .terminal(let kind):
                completion(launchTerminal(kind: kind, template: template, prompt: prompt))
            case .editor(let editor):
                // Editor targets require the tool's integration data. Missing data
                // is a defensive (backfilled) case — fail honestly, no fallback.
                guard let integration = command.editorIntegration else {
                    completion(.failure(.editorIntegrationMissing(editor)))
                    return
                }
                let url = DeepLinkBuilder.url(editor: editor, integration: integration, prompt: prompt)
                completion(openURL(url) ? .success(())
                                        : .failure(.editorDeepLinkRejected(editor)))
            }
        case .openApp(let bundleID):
            // Legacy path — the "open Claude desktop app" command was removed.
            // Retained as a decodable case for backward compat with old settings
            // files; any that survive migration fail here rather than crashing.
            completion(.failure(.appNotFound(bundleID)))
        case .runShell(let script):
            do { try runShell(script); completion(.success(())) }
            catch { completion(.failure(.shellFailed(error.localizedDescription))) }
        case .sendCodexVoiceShortcut:
            // macOS grants this capability specifically as permission to post
            // events. `AXIsProcessTrusted()` is broader and can report false
            // for an otherwise-authorized event poster, so use the matching
            // Core Graphics preflight here.
            if !CGPreflightPostEventAccess() {
                // Permission is requested only by the explicit menu setup action.
                // A wake phrase must never surprise someone with a macOS privacy
                // dialog, and reporting the missing capability here keeps the
                // user on a clear, repeatable path to repair it.
                completion(.failure(.shellFailed("Choose Enable ChatGPT Voice Shortcut in the Hey Codex menu, then try again.")))
                return
            }
            let shortcut = settings.voiceShortcut
            guard shortcut.isUsable, let keyCode = shortcut.virtualKeyCode else {
                completion(.failure(.shellFailed("Choose a supported Voice shortcut key in Hey Codex settings.")))
                return
            }
            guard let source = CGEventSource(stateID: .hidSystemState) else {
                completion(.failure(.shellFailed("Could not create the global ChatGPT Voice shortcut event.")))
                return
            }
            // Always post to the system HID tap, never to ChatGPT's pid — even
            // when ChatGPT is frontmost. ChatGPT registers the Voice shortcut
            // through Electron's globalShortcut, which on macOS is Carbon
            // `RegisterEventHotKey` (the Codex Framework binary imports it).
            // Carbon hot keys are dispatched by the window server off the system
            // event stream; `CGEvent.postToPid` injects straight into a process's
            // own event queue and bypasses that dispatch, so the hot key handler
            // never fires. Focus is irrelevant to a Carbon hot key — the same
            // global post reaches it whether or not ChatGPT is in front.
            func post(_ event: CGEvent) {
                event.post(tap: .cghidEventTap)
            }

            // A shortcut is a physical key sequence, not simply a letter event
            // with modifier bits painted onto it. Some apps (including the new
            // Voice surface) track each modifier transition and reject the
            // abbreviated form. Emit the complete key lifecycle in the same
            // order a keyboard does: modifiers down, key down/up, modifiers up.
            let modifiers: [(keyCode: CGKeyCode, flag: CGEventFlags)] = [
                shortcut.control ? (59, .maskControl) : nil,   // left Control
                shortcut.option ? (58, .maskAlternate) : nil,  // left Option
                shortcut.command ? (55, .maskCommand) : nil,   // left Command
            ].compactMap { $0 }
            var flags: CGEventFlags = []
            for modifier in modifiers {
                flags.insert(modifier.flag)
                guard let event = CGEvent(keyboardEventSource: source,
                                          virtualKey: modifier.keyCode,
                                          keyDown: true) else {
                    completion(.failure(.shellFailed("Could not create the global ChatGPT Voice shortcut event.")))
                    return
                }
                event.flags = flags
                post(event)
            }
            guard let down = CGEvent(keyboardEventSource: source,
                                     virtualKey: CGKeyCode(keyCode), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source,
                                   virtualKey: CGKeyCode(keyCode), keyDown: false) else {
                completion(.failure(.shellFailed("Could not create the global ChatGPT Voice shortcut event.")))
                return
            }
            down.flags = flags
            up.flags = flags
            post(down)
            post(up)
            for modifier in modifiers.reversed() {
                flags.remove(modifier.flag)
                guard let event = CGEvent(keyboardEventSource: source,
                                          virtualKey: modifier.keyCode,
                                          keyDown: false) else {
                    completion(.failure(.shellFailed("Could not release the global ChatGPT Voice shortcut event.")))
                    return
                }
                event.flags = flags
                post(event)
            }
            completion(.success(()))
        }
    }

    private func launchTerminal(kind: TerminalKind, template: String, prompt: String?)
        -> Result<Void, LaunchFailure> {
        let rendered = Self.render(template, prompt: prompt)
        do {
            try launcherFor(kind).launch(LaunchSpec(
                directory: settings.projectDirectory,
                executable: rendered.executable,
                prompt: rendered.prompt))
            return .success(())
        } catch let e as TerminalLaunchError {
            switch e {
            case .notInstalled:          return .failure(.terminalNotInstalled(kind))
            case .automationFailed(let m): return .failure(.terminalAutomationFailed(kind, m))
            }
        } catch {
            return .failure(.terminalAutomationFailed(kind, error.localizedDescription))
        }
    }

    /// Splits a rendered template into (executable, prompt) for LaunchSpec.
    /// "claude {prompt}" + "fix" → ("claude", "fix"); + nil → ("claude", nil).
    static func render(_ template: String, prompt: String?) -> (executable: String, prompt: String?) {
        if let p = prompt, !p.isEmpty {
            // Replace {prompt} with a marker we then peel back into LaunchSpec.prompt
            // so shell-escaping stays in LaunchSpec. If no placeholder, append.
            if template.contains("{prompt}") {
                let exe = template.replacingOccurrences(of: "{prompt}", with: "").trimmingCharacters(in: .whitespaces)
                return (exe, p)
            }
            return (template.trimmingCharacters(in: .whitespaces), p)
        }
        let exe = template.replacingOccurrences(of: "{prompt}", with: "").trimmingCharacters(in: .whitespaces)
        return (exe, nil)
    }

    public static func defaultRunShell(_ script: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        try p.run()
    }
    /// Opens the editor deep link. Returns whether a handler claimed the scheme —
    /// best-effort (the OS doesn't report whether the editor honored the link).
    public static func defaultOpenURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
