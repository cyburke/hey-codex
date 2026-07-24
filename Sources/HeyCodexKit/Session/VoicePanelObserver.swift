import AppKit
import CoreGraphics
import Foundation

/// One ChatGPT-owned window reduced to the only three facts this helper reads.
///
/// Deliberately *not* included: position, size, title, or any window contents.
/// Those are the brittle properties — OpenAI can move, resize, restyle, or
/// rename the Voice panel without changing whether ChatGPT's own process owns a
/// floating window that is currently on screen.
public struct VoiceWindow: Equatable, Sendable {
    public let ownerProcessIdentifier: Int32
    public let layer: Int
    public let isOnscreen: Bool

    public init(ownerProcessIdentifier: Int32, layer: Int, isOnscreen: Bool) {
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.layer = layer
        self.isOnscreen = isOnscreen
    }
}

/// Reads whether ChatGPT's Voice panel is currently on screen.
///
/// ChatGPT exposes no session-state API, but Voice runs in a floating panel
/// owned by ChatGPT's own process. The panel is persistent — it is not created
/// and destroyed per session, it toggles between on screen and off screen — so
/// the signal is a visibility check, never a "did a new window appear" check.
///
/// This needs no permission beyond what the app already holds: window owner,
/// layer, and on-screen state are readable without Screen Recording access.
/// Window *titles* are not, and are never read here.
public struct VoicePanelObserver: Sendable {
    public static let chatGPTBundleIdentifier = "com.openai.codex"

    private let runningProcessIdentifier: @Sendable () -> Int32?
    private let windowList: @Sendable () -> [VoiceWindow]

    public init(runningProcessIdentifier: @escaping @Sendable () -> Int32? = VoicePanelObserver.chatGPTProcessIdentifier,
                windowList: @escaping @Sendable () -> [VoiceWindow] = VoicePanelObserver.currentWindows) {
        self.runningProcessIdentifier = runningProcessIdentifier
        self.windowList = windowList
    }

    /// Whether a Voice panel is on screen right now.
    public func isPanelVisible() -> Bool {
        Self.isPanelVisible(chatGPTProcessIdentifier: runningProcessIdentifier(),
                            windows: windowList())
    }

    /// The rule, extracted so it is testable without a window server.
    ///
    /// A Voice panel is a window that (a) belongs to ChatGPT's main process,
    /// (b) floats above normal document windows, and (c) is on screen. The
    /// process check matters: ChatGPT's Computer Use overlay is also a floating
    /// window but runs in a *separate* process, so filtering by pid excludes it
    /// without knowing anything about how it looks.
    public static func isPanelVisible(chatGPTProcessIdentifier: Int32?,
                                      windows: [VoiceWindow]) -> Bool {
        guard let pid = chatGPTProcessIdentifier else { return false }
        return windows.contains { window in
            window.ownerProcessIdentifier == pid && window.layer > 0 && window.isOnscreen
        }
    }

    public static let chatGPTProcessIdentifier: @Sendable () -> Int32? = {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: chatGPTBundleIdentifier)
            .first?
            .processIdentifier
    }

    public static let currentWindows: @Sendable () -> [VoiceWindow] = {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int else { return nil }
            let onscreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            return VoiceWindow(ownerProcessIdentifier: pid, layer: layer, isOnscreen: onscreen)
        }
    }
}
