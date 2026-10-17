import Foundation

/// App-wide settings, stored as `Settings.json`.
public struct AppSettings: Codable, Equatable, Sendable {
    public var onboardingCompleted = false
    public var activeEngineVersion: String?
    public var gamesFolder: URL?
    public var verboseLogs = false
    public var engineManifestURL: URL?
    /// Retina mode last written into each bottle's registry (so it's only rewritten when it changes).
    public var appliedRetina: [String: Bool] = [:]
    /// Engine version that last started each bottle. A bottle's wineserver belongs to one engine,
    /// so another engine can only use the bottle after it stops. Optional: older files don't have it.
    public var bottleEngines: [String: String]?
    /// Macade Pro. `nil` until the user has decided (debug builds then count as unlocked).
    public var proUnlocked: Bool?
    /// Stores the user turned off on the home screen (`StoreKind` raw values).
    public var hiddenStores: [String]?
    /// Stores turned on that start off (GOG, Ubisoft, EA), as `StoreKind` raw values.
    public var shownStores: [String]?
    /// Mac driver options last written into each bottle's registry, by bottle then value name.
    public var appliedMacDriver: [String: [String: Bool]]?
    /// PlayStation-style pads (DualShock 4, DualSense, Backbone One PlayStation Edition) appear to games as Xbox
    /// controllers. `nil` means the default, which is on.
    public var playStationAsXbox: Bool?
    /// What `playStationAsXbox` was last written into each bottle's registry, by bottle.
    public var appliedControllerCompat: [String: Bool]?
    /// "system", "light" or "dark"; `nil` follows the system.
    public var appearance: String?
    /// Game page layout: "magazine" (text on the art's color) or "panels"; `nil` is magazine.
    public var gamePageStyle: String?
    /// Pro extras. `nil` means the default, which is on.
    public var keepAwakeWhilePlaying: Bool?
    public var showMenuBarLauncher: Bool?
    public var autoBackupSaves: Bool?
    /// Where save backups go (iCloud Drive or a folder the user picked).
    public var backupFolder: URL?
    /// The version of the license agreement the user agreed to (`EULA.version` in the app). `nil` until they do.
    public var acceptedEULA: String?

    public init() {}
}

/// Atomic JSON persistence for settings and the library cache.
public struct JSONStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load(default fallback: Value) -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601        // must match `save`
        guard let data = try? Data(contentsOf: url) else { return fallback }
        guard let value = try? decoder.decode(Value.self, from: data) else {
            // Keep the unreadable file for inspection instead of letting the next save overwrite it.
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return fallback
        }
        return value
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
