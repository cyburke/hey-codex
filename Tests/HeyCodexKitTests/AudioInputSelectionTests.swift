import XCTest
@testable import HeyCodexKit

final class AudioInputSelectionTests: XCTestCase {
    private let builtIn = AudioInputDevice(uid: "builtin", name: "Built-in")
    private let headset = AudioInputDevice(uid: "airpods", name: "AirPods Pro")
    private let monitor = AudioInputDevice(uid: "monitor", name: "C3422WE")

    func test_noPreferenceFollowsTheSystemDefault() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: nil,
                                                  available: [builtIn, monitor],
                                                  systemDefaultUID: "monitor"), "monitor")
    }

    func test_aChosenDeviceWinsOverTheSystemDefault() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "airpods",
                                                  available: [builtIn, headset],
                                                  systemDefaultUID: "builtin"), "airpods")
    }

    /// The case that would otherwise leave the app deaf: a headset that has been
    /// unplugged or a monitor that has been switched off.
    func test_anUnavailableChoiceFallsBackToTheSystemDefault() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "airpods",
                                                  available: [builtIn, monitor],
                                                  systemDefaultUID: "monitor"), "monitor")
    }

    func test_fallsBackToAnyDeviceWhenTheDefaultIsAlsoGone() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "airpods",
                                                  available: [monitor],
                                                  systemDefaultUID: "vanished"), "monitor")
    }

    /// A Mac mini with nothing plugged in has no microphone at all.
    func test_noDevicesResolvesToNothingRatherThanGuessing() {
        XCTAssertNil(AudioInputSelection.resolve(preferredUID: "airpods",
                                                 available: [],
                                                 systemDefaultUID: "airpods"))
    }

    func test_reportsWhenTheSavedChoiceIsMissing() {
        XCTAssertTrue(AudioInputSelection.isPreferenceUnavailable(preferredUID: "airpods",
                                                                  available: [builtIn]))
        XCTAssertFalse(AudioInputSelection.isPreferenceUnavailable(preferredUID: "airpods",
                                                                   available: [builtIn, headset]))
        // Automatic can never be "unavailable".
        XCTAssertFalse(AudioInputSelection.isPreferenceUnavailable(preferredUID: nil,
                                                                   available: []))
    }

    /// The preference is kept, not rewritten, so reconnecting the headset picks it
    /// up again without the user having to choose it a second time.
    func test_fallingBackDoesNotDiscardThePreference() {
        let preferred = "airpods"
        _ = AudioInputSelection.resolve(preferredUID: preferred,
                                        available: [monitor],
                                        systemDefaultUID: "monitor")
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: preferred,
                                                  available: [monitor, headset],
                                                  systemDefaultUID: "monitor"), "airpods")
    }
}
