import Foundation

/// Reads Steam's on-disk state inside the Steam bottle (plan §4.6).
public enum SteamLibrary {
    /// Steam tools and redistributables that aren't games.
    static let ignoredAppIDs: Set<String> = ["228980"]
    static let ignoredNamePrefixes = ["Steamworks", "Proton", "Steam Linux Runtime", "SteamVR"]

    public static func artworkURL(appID: String, _ file: String) -> URL? {
        URL(string: "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/\(appID)/\(file)")
    }

    /// All installed or installing games across every Steam library folder in the bottle.
    public static func scan(bottle: Bottle) -> [Game] {
        let dirs = libraryDirectories(bottle: bottle)
        var games: [Game] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   let game = parseManifest(text, steamapps: dir) { games.append(game) }
            }
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public static func libraryDirectories(bottle: Bottle) -> [URL] {
        let steamapps = bottle.steamDirectory.appendingPathComponent("steamapps")
        var dirs = [steamapps]
        if let text = try? String(contentsOf: steamapps.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8),
           let root = try? VDFParser.parse(text),
           let folders = root["libraryfolders"]?.entries {
            for (_, folder) in folders {
                if let p = folder["path"]?.string, let url = bottle.unixURL(forWindowsPath: p) {
                    dirs.append(url.appendingPathComponent("steamapps"))
                }
            }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Parses one `appmanifest_<id>.acf`. Returns nil for tools and unreadable manifests.
    public static func parseManifest(_ text: String, steamapps: URL) -> Game? {
        guard let root = try? VDFParser.parse(text), let state = root["AppState"],
              let appID = state["appid"]?.string, let name = state["name"]?.string,
              !ignoredAppIDs.contains(appID),
              !ignoredNamePrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }

        let flags = Int(state["StateFlags"]?.string ?? "") ?? 0
        let installed = flags & 4 != 0                    // fully installed
        let toDownload = Double(state["BytesToDownload"]?.string ?? "") ?? 0
        let downloaded = Double(state["BytesDownloaded"]?.string ?? "") ?? 0
        let progress: Double? = (!installed || flags & (2 | 1024 | 256) != 0) && toDownload > 0
            ? min(1, downloaded / toDownload) : nil

        let installDir = state["installdir"]?.string
        return Game(
            store: .steam, storeID: appID, title: name, isInstalled: installed,
            installPath: installDir.map { steamapps.appendingPathComponent("common/\($0)") },
            sizeOnDisk: Int64(state["SizeOnDisk"]?.string ?? ""),
            coverURL: artworkURL(appID: appID, "library_600x900.jpg"),
            heroURL: artworkURL(appID: appID, "library_hero.jpg"),
            installProgress: progress)
    }
}
