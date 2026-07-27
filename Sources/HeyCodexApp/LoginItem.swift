import HeyCodexKit
import ServiceManagement

/// Whether Hey Codex starts itself when you log in.
///
/// A menu bar app that listens for a wake phrase is useless the moment it is not
/// running, and nothing restarts it after a reboot. Before this, every restart
/// left the app silently absent until the user noticed the icon was gone and
/// opened it by hand.
///
/// `SMAppService.mainApp` is the supported way to do this without a helper
/// bundle or a hand-written launch agent. macOS shows the result under Login
/// Items in System Settings, where the user can switch it off, which is the
/// behaviour anyone would expect of a background app that starts itself.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns whether it ended up in the requested state. A registration can be
    /// refused (macOS keeps a per-app record the user controls), and silently
    /// reporting success would leave a menu checkmark that lies.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return true }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.launch.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return isEnabled == enabled
    }

    /// Whether macOS is refusing this because the user switched it off in System
    /// Settings, which the app must not fight.
    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
