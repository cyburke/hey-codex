import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Reports whether an editor can actually host a given tool: the editor app is
/// installed AND the tool's extension (matching its glob) is present in the
/// editor's extensions directory.
///
/// `home` and `appInstalled` are injectable so the rule is unit-testable against
/// a temp directory and a fake install table.
public struct EditorAvailability: Sendable {
    private let home: URL
    private let appInstalled: @Sendable (String) -> Bool

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                appInstalled: @escaping @Sendable (String) -> Bool = EditorAvailability.defaultAppInstalled) {
        self.home = home
        self.appInstalled = appInstalled
    }

    /// App bundle present AND tool extension installed.
    public func isReady(_ editor: EditorKind, integration: EditorIntegration) -> Bool {
        appInstalled(editor.bundleID) && hasExtension(editor, glob: integration.extensionGlob)
    }

    /// Whether a directory matching `glob` (e.g. `anthropic.claude-code-*`)
    /// exists in the editor's extensions directory.
    public func hasExtension(_ editor: EditorKind, glob: String) -> Bool {
        let dir = home.appendingPathComponent(editor.extensionsSubpath, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        let prefix = glob.hasSuffix("*") ? String(glob.dropLast()) : glob
        return entries.contains { $0.hasPrefix(prefix) }
    }

    public static func defaultAppInstalled(_ bundleID: String) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        #else
        return false
        #endif
    }
}
