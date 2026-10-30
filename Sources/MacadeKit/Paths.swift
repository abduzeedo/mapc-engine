import Foundation

/// Single source of truth for every directory Macade touches.
/// Set `MACADE_HOME` to redirect everything (tests, integration runs).
public struct Paths: Sendable {
    public let home: URL

    public init(home: URL? = nil) {
        if let home {
            self.home = home
        } else if let override = ProcessInfo.processInfo.environment["MACADE_HOME"], !override.isEmpty {
            self.home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.home = Self.current(support.appendingPathComponent("MaPC", isDirectory: true),
                                     legacy: ["Arcadexe", "Macade"].map { support.appendingPathComponent($0, isDirectory: true) })
        }
    }

    public var engines: URL { home.appendingPathComponent("Engines", isDirectory: true) }
    public var tools: URL { home.appendingPathComponent("Tools", isDirectory: true) }
    /// Apple's D3DMetal, copied from the user's own Game Porting Toolkit download (never shipped by Macade).
    public var d3dMetal: URL { home.appendingPathComponent("D3DMetal", isDirectory: true) }
    public var bottles: URL { home.appendingPathComponent("Bottles", isDirectory: true) }
    public var artwork: URL { home.appendingPathComponent("Artwork", isDirectory: true) }
    public var logs: URL { home.appendingPathComponent("Logs", isDirectory: true) }
    public var legendaryConfig: URL { home.appendingPathComponent("legendary", isDirectory: true) }
    /// gogdl's tokens and manifests (owner-only, like Legendary's).
    public var gogConfig: URL { home.appendingPathComponent("gog", isDirectory: true) }
    /// Nile's Amazon tokens (encrypted by Nile, owner-only too), library and installs.
    public var amazonConfig: URL { home.appendingPathComponent("amazon", isDirectory: true) }
    public var libraryFile: URL { home.appendingPathComponent("Library.json") }
    public var settingsFile: URL { home.appendingPathComponent("Settings.json") }
    /// The signed-in Steam account's owned games, cached (see `SteamOwnedGames`).
    public var steamOwnedFile: URL { home.appendingPathComponent("SteamOwned.json") }
    /// One entry per play session (start and length), for the playtime stats.
    public var sessionsFile: URL { home.appendingPathComponent("Sessions.json") }

    public func engine(version: String) -> URL { engines.appendingPathComponent(version, isDirectory: true) }
    public func bottle(_ name: String) -> URL { bottles.appendingPathComponent(name, isDirectory: true) }
    public func gameLogs(_ gameID: String) -> URL {
        logs.appendingPathComponent(gameID.replacingOccurrences(of: ":", with: "-"), isDirectory: true)
    }

    /// Default location for installed games.
    public var defaultGamesFolder: URL {
        let games = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games", isDirectory: true)
        return Self.current(games.appendingPathComponent("MaPC", isDirectory: true),
                            legacy: ["Arcadexe", "Macade"].map { games.appendingPathComponent($0, isDirectory: true) })
    }

    /// The app was called Macade, then Arcadexe. Their folders stay in use where they exist: bottles,
    /// Legendary's and gogdl's configs and engine links hold absolute paths, so moving them would break
    /// installed games. `legacy` is in order of preference.
    static func current(_ url: URL, legacy: [URL]) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        return legacy.first { fm.fileExists(atPath: $0.path) } ?? url
    }

    public func createDirectories() throws {
        for dir in [engines, tools, bottles, artwork, logs, legendaryConfig, gogConfig, amazonConfig] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Legendary keeps Epic login tokens here: owner-only, whatever the umask says.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legendaryConfig.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gogConfig.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: amazonConfig.path)
    }
}
