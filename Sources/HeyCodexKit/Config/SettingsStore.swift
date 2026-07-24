import Foundation

/// Loads/saves Settings as JSON. Defaults to Application Support; injectable
/// fileURL for tests. Missing/corrupt file -> Settings.default.
public final class SettingsStore {
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public convenience init() {
        let fm = FileManager.default
        let dir = fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyCodex", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("settings.json")
        // Copy, never move, legacy data so an existing upstream install remains
        // untouched. The decoded migration below replaces obsolete routing.
        if !fm.fileExists(atPath: destination.path),
           let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HeyClaude/settings.json"),
           fm.fileExists(atPath: legacy.path) {
            try? fm.copyItem(at: legacy, to: destination)
        }
        self.init(fileURL: destination)
    }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        var migrated = s
        migrated.commands = Command.seededDefaults
        migrated.defaultCommandID = "codex-voice"
        migrated.promptCommandID = "codex-voice"
        migrated.wakePhrase = WakePhrase.normalize(s.wakePhrase) ?? "Hey Codex"
        return migrated
    }

    public func save(_ settings: Settings) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: fileURL, options: .atomic)
    }
}
