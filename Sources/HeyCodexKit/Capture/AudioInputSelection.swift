import Foundation

/// A microphone the user could choose.
public struct AudioInputDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public enum AudioInputSelection {
    /// Which device to actually open.
    ///
    /// Devices come and go: headsets get unplugged, Bluetooth drops, a monitor
    /// gets switched off. A saved preference that no longer exists must fall back
    /// rather than leave the app deaf and still claiming to listen, and it must
    /// keep the preference so the device is picked up again when it returns.
    ///
    /// `nil` preferred means follow the system default, which is what most people
    /// want and what "Automatic" selects.
    public static func resolve(preferredUID: String?,
                               available: [AudioInputDevice],
                               systemDefaultUID: String?) -> String? {
        if let preferredUID, available.contains(where: { $0.uid == preferredUID }) {
            return preferredUID
        }
        if let systemDefaultUID, available.contains(where: { $0.uid == systemDefaultUID }) {
            return systemDefaultUID
        }
        return available.first?.uid
    }

    /// Whether a saved choice is currently unavailable, so the UI can say the app
    /// fell back instead of pretending the preference is in effect.
    public static func isPreferenceUnavailable(preferredUID: String?,
                                              available: [AudioInputDevice]) -> Bool {
        guard let preferredUID else { return false }
        return !available.contains { $0.uid == preferredUID }
    }
}
