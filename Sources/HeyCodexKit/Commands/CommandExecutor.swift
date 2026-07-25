import AppKit
import Foundation

/// Executes a resolved Command. Side effects are injected so it's testable
/// (mock runShell) and the real defaults live in one place.
///
/// `execute` reports its outcome through a `completion` closure rather than a
/// synchronous `throws`: the typed `LaunchFailure` crosses to the caller intact
/// (it's `Sendable`) so the UI can show a specific, actionable message, never a
/// bare `Bool`.
public struct CommandExecutor: Sendable {
    private let settings: Settings
    private let runShell: @Sendable (String) throws -> Void

    public init(settings: Settings,
                runShell: @escaping @Sendable (String) throws -> Void = CommandExecutor.defaultRunShell) {
        self.settings = settings
        self.runShell = runShell
    }

    /// Runs the command and reports success or a typed failure via `completion`.
    /// All paths call `completion` inline (synchronous).
    public func execute(_ command: Command, prompt: String?,
                        completion: @escaping @Sendable (Result<Void, LaunchFailure>) -> Void) {
        switch command.kind {
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
                completion(.failure(.shellFailed("Hey Codex needs Accessibility permission before it can press the hotkey. Open Setup from the menu bar to sort that out.")))
                return
            }
            let shortcut = settings.voiceShortcut
            guard shortcut.isUsable, let keyCode = shortcut.virtualKeyCode else {
                completion(.failure(.shellFailed("That hotkey key is not supported. Pick another one in Hey Codex settings.")))
                return
            }
            guard let source = CGEventSource(stateID: .hidSystemState) else {
                completion(.failure(.shellFailed("macOS would not let Hey Codex build the keystroke. Try again in a moment.")))
                return
            }
            // Always post to the system HID tap, never to ChatGPT's pid, even
            // when ChatGPT is frontmost. ChatGPT registers the Voice shortcut
            // through Electron's globalShortcut, which on macOS is Carbon
            // `RegisterEventHotKey` (the Codex Framework binary imports it).
            // Carbon hot keys are dispatched by the window server off the system
            // event stream; `CGEvent.postToPid` injects straight into a process's
            // own event queue and bypasses that dispatch, so the hot key handler
            // never fires. Focus is irrelevant to a Carbon hot key - the same
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
                    completion(.failure(.shellFailed("macOS would not let Hey Codex build the keystroke. Try again in a moment.")))
                    return
                }
                event.flags = flags
                post(event)
            }
            guard let down = CGEvent(keyboardEventSource: source,
                                     virtualKey: CGKeyCode(keyCode), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source,
                                   virtualKey: CGKeyCode(keyCode), keyDown: false) else {
                completion(.failure(.shellFailed("macOS would not let Hey Codex build the keystroke. Try again in a moment.")))
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
                    completion(.failure(.shellFailed("macOS would not let Hey Codex finish the keystroke. Try again in a moment.")))
                    return
                }
                event.flags = flags
                post(event)
            }
            completion(.success(()))
        }
    }

    public static func defaultRunShell(_ script: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        try p.run()
    }
}
