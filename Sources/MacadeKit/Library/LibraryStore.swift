import Foundation

/// Per-game data owned by the user (survives library refreshes).
public struct UserGameData: Codable, Equatable, Sendable {
    public var profile = LaunchProfile()
    public var lastPlayed: Date?
    public var playTime: TimeInterval = 0
    /// The folders the user chose to back up for this game (Pro).
    public var saveSources: [SaveSource]?
    public var lastSaveBackup: Date?
    public init() {}
}

/// What `Library.json` holds: the last known games (for an instant first paint) plus user data.
public struct LibraryFile: Codable, Equatable, Sendable {
    public var games: [Game] = []
    public var userData: [String: UserGameData] = [:]
    public init() {}
}

/// Merges provider results and keeps user-owned fields across refreshes.
public struct LibraryStore: Sendable {
    let store: JSONStore<LibraryFile>

    public init(paths: Paths) { store = JSONStore(url: paths.libraryFile) }

    public func load() -> LibraryFile { store.load(default: LibraryFile()) }
    public func save(_ file: LibraryFile) { try? store.save(file) }

    /// Replaces one store's games, leaving the other store's cached games alone.
    public static func merged(cached: [Game], replacing kind: StoreKind, with fresh: [Game]) -> [Game] {
        (cached.filter { $0.store != kind } + fresh)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Drops user data for games that no longer exist in any store (keeps data for cached games).
    public static func pruned(_ data: [String: UserGameData], keeping games: [Game]) -> [String: UserGameData] {
        let ids = Set(games.map(\.id))
        return data.filter { ids.contains($0.key) }
    }
}
