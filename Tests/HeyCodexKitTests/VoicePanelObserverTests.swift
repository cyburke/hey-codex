import XCTest
@testable import HeyCodexKit

final class VoicePanelObserverTests: XCTestCase {
    private let chatGPT: Int32 = 4242

    private func window(pid: Int32, layer: Int, onscreen: Bool) -> VoiceWindow {
        VoiceWindow(ownerProcessIdentifier: pid, layer: layer, isOnscreen: onscreen)
    }

    func test_floatingOnscreenWindowOwnedByChatGPTMeansVoiceIsUp() {
        XCTAssertTrue(VoicePanelObserver.isPanelVisible(
            chatGPTProcessIdentifier: chatGPT,
            windows: [window(pid: chatGPT, layer: 0, onscreen: true),
                      window(pid: chatGPT, layer: 3, onscreen: true)]))
    }

    /// The panel is persistent: it toggles on and off screen rather than being
    /// created and destroyed. Off screen is the closed state, not a missing one.
    func test_offscreenFloatingWindowMeansVoiceIsClosed() {
        XCTAssertFalse(VoicePanelObserver.isPanelVisible(
            chatGPTProcessIdentifier: chatGPT,
            windows: [window(pid: chatGPT, layer: 0, onscreen: true),
                      window(pid: chatGPT, layer: 3, onscreen: false)]))
    }

    func test_mainDocumentWindowAloneIsNotVoice() {
        XCTAssertFalse(VoicePanelObserver.isPanelVisible(
            chatGPTProcessIdentifier: chatGPT,
            windows: [window(pid: chatGPT, layer: 0, onscreen: true)]))
    }

    /// ChatGPT's Computer Use overlay is also a floating on-screen window, but
    /// it runs in a separate process. Filtering by pid excludes it without
    /// knowing anything about its size, position, or title.
    func test_floatingWindowFromAnotherProcessIsNotVoice() {
        XCTAssertFalse(VoicePanelObserver.isPanelVisible(
            chatGPTProcessIdentifier: chatGPT,
            windows: [window(pid: 9999, layer: 3, onscreen: true)]))
    }

    func test_chatGPTNotRunningMeansVoiceIsNotUp() {
        XCTAssertFalse(VoicePanelObserver.isPanelVisible(
            chatGPTProcessIdentifier: nil,
            windows: [window(pid: chatGPT, layer: 3, onscreen: true)]))
    }
}
