import Foundation

/// A stand-in `EpicGamesLauncher.exe` that Rockstar's Epic games start through.
///
/// The Rockstar Games Launcher only treats a game bought on Epic as owned when it sees the Epic Games Launcher as the
/// process that started it: it opens that process and reads it. Legendary starts the game straight from Wine, so the
/// launcher logs "Could not do OpenProcess on parent process" and "Relaunch from third party platform required",
/// can't hand the game back to Epic, and shows "Buy now" for Red Dead Redemption 2 (Tanmay, MaPC 1.1.33, 2026-11-21;
/// the same files showed Play, version "Epic Games Launcher", on Windows). The stand-in (`engine/epic-launcher-standin`)
/// starts the game as its child and waits, like Heroic's `USE_FAKE_EPIC_EXE`. Legendary puts it in front of the game
/// when `LEGENDARY_WRAPPER_EXE` is set (Heroic's build has supported it since 0.20.37).
public enum EpicLauncherStandIn {
    /// Where the stand-in lives in the Epic environment: the path Heroic uses, so the launcher sees the same thing.
    static let windowsPath = #"C:\windows\command\EpicGamesLauncher.exe"#
    static let bottlePath = "windows/command/EpicGamesLauncher.exe"
    /// Built into the stand-in, so MaPC only ever replaces its own copy.
    static let marker = Data("mapc-epic-launcher-standin/".utf8)

    /// Built from `engine/epic-launcher-standin` into the app's Resources (see the app's project.yml).
    public static var bundled: URL? { Bundle.main.url(forResource: "epic-launcher-standin", withExtension: "exe") }

    /// Rockstar's games start with a `Play<Game>.exe` in the game's folder (GTA V, RDR2, Max Payne 3).
    public static func isNeeded(for game: Game) -> Bool {
        guard game.store == .epic, let dir = game.installPath,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains { GraphicsProbe.rockstarStarters.contains($0.lowercased()) }
    }

    /// Copies the stand-in into `bottle` unless the same copy is there. Something that isn't ours is left alone.
    /// Returns whether the stand-in is in place.
    @discardableResult
    static func install(in bottle: Bottle, from source: URL?) -> Bool {
        let fm = FileManager.default
        guard bottle.exists, let source, let data = fm.contents(atPath: source.path), data.range(of: marker) != nil
        else { return false }
        let target = bottle.driveC.appendingPathComponent(bottlePath)
        if let current = fm.contents(atPath: target.path) {
            if current == data { return true }
            if current.range(of: marker) == nil { return false }
        }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return true
        } catch { return false }
    }

    /// The environment that has Legendary start `game` through the stand-in, after putting it in `bottle`.
    /// Empty for every other game, or when the app has no stand-in to install.
    public static func environment(for game: Game, bottle: Bottle, source: URL? = bundled) -> [String: String] {
        guard isNeeded(for: game), install(in: bottle, from: source) else { return [:] }
        return ["LEGENDARY_WRAPPER_EXE": windowsPath]
    }
}
