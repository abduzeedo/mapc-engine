import Foundation

/// A folder that probably holds a game's saves, and why it was suggested.
public struct SaveCandidate: Identifiable, Hashable, Sendable {
    public enum Reason: String, Sendable {
        /// Steam's own per-game folder (Steam Cloud).
        case steamCloud
        /// The folder is named like the game.
        case nameMatch
        /// A folder named like saves inside the game's own folder.
        case installFolder
        /// Files in it changed since the game was last started.
        case recentlyChanged

        var rank: Int {
            switch self {
            case .steamCloud: 0
            case .nameMatch: 1
            case .installFolder: 2
            case .recentlyChanged: 3
            }
        }
    }

    public var source: SaveSource
    public var reason: Reason
    public var bytes: Int64
    public var files: Int
    public var modified: Date?

    public var id: String { source.id }
}

/// Finds save folders in a bottle. Windows games keep saves in many places and nothing records which, so
/// this looks for folders named like the game and for folders the last session changed, and the user
/// confirms the result. It never walks the Mac's whole Documents folder (Wine links it into the bottle).
public enum SaveLocator {
    /// Folders that hold launcher, runtime and cache data, never a game's saves.
    static let noise: Set<String> = [
        "microsoft", "temp", "tmp", "packages", "cef", "steam", "d3dscache", "nvidia", "nvidiacorporation", "programs",
        "crashdumps", "crashpad", "google", "mozilla", "epicgameslauncher", "unrealengine", "unrealenginelauncher",
        "origin", "eadesktop", "ubisoft", "ubisoft game launcher", "gogcom", "gog.com", "galaxy", "gog galaxy",
        "wine", "fontconfig", "cache", "caches", "logs", "history", "windows", "vulkan", "dxvk", "mesa_shader_cache",
        "amd", "intel", "qtwebengine", "chromium", "discord", "legendary", "redist", "installer", "applications",
    ]

    static let installSaveNames: Set<String> = ["save", "saves", "savegame", "savegames", "savedata", "savedgames", "profiles", "userdata"]

    public static func candidates(title: String, steamAppID: String?, roots: SaveRoots,
                                  changedSince: Date? = nil) -> [SaveCandidate] {
        let keys = nameKeys(title)
        var found: [String: SaveCandidate] = [:]

        func add(_ source: SaveSource, _ reason: SaveCandidate.Reason, at url: URL) {
            let m = FileScan.measure(url, limit: 5_000)
            guard m.files > 0 else { return }
            let candidate = SaveCandidate(source: source, reason: reason, bytes: m.bytes, files: m.files, modified: m.newest)
            if let existing = found[source.id], existing.reason.rank <= reason.rank { return }
            found[source.id] = candidate
        }

        func recentlyChanged(_ url: URL) -> Bool {
            guard let since = changedSince else { return false }
            return (FileScan.measure(url, limit: 5_000).newest ?? .distantPast) >= since
        }

        /// A file directly inside `url` changed since the game was last started.
        func recentDirectFile(_ url: URL) -> Bool {
            guard let since = changedSince, let names = listing(url) else { return false }
            return names.contains { name in
                let file = url.appendingPathComponent(name)
                return FileScan.isRegularFile(file) && (FileScan.attributes(file)?[.modificationDate] as? Date ?? .distantPast) >= since
            }
        }

        /// Looks at the folders inside `parent` (relative path `prefix`), `depth` levels down.
        func scan(root: SaveRoot, parent: URL, prefix: String, depth: Int) {
            guard let names = listing(parent) else { return }
            for name in names where !isNoise(name) {
                let url = parent.appendingPathComponent(name, isDirectory: true)
                guard FileScan.isDirectory(url) else { continue }
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                if matches(name, keys: keys) {
                    add(SaveSource(root: root, path: path), .nameMatch, at: url)
                } else if depth > 1 {
                    if recentDirectFile(url) { add(SaveSource(root: root, path: path), .recentlyChanged, at: url) }
                    scan(root: root, parent: url, prefix: path, depth: depth - 1)
                } else if recentlyChanged(url) {
                    add(SaveSource(root: root, path: path), .recentlyChanged, at: url)
                }
            }
        }

        // Steam Cloud's per-game folder.
        if let appID = steamAppID, let userdata = roots.steamUserdata, let accounts = listing(userdata) {
            for account in accounts where account != "0" {
                let url = userdata.appendingPathComponent(account).appendingPathComponent(appID)
                if FileScan.isDirectory(url) { add(SaveSource(root: .steamUserdata, path: "\(account)/\(appID)"), .steamCloud, at: url) }
            }
        }

        // AppData: Company/Game folders are common, so look two levels down.
        for root in [SaveRoot.roaming, .local, .localLow] {
            if let base = roots.resolvedBase(root) { scan(root: root, parent: base, prefix: "", depth: 2) }
        }
        if let base = roots.resolvedBase(.savedGames) { scan(root: .savedGames, parent: base, prefix: "", depth: 1) }

        // Documents is the Mac's own folder: only folders named like the game, and the "My Games" and
        // "Saved Games" folders games conventionally use.
        if let docs = roots.resolvedBase(.documents), let names = listing(docs) {
            for name in names where !isNoise(name) {
                let url = docs.appendingPathComponent(name, isDirectory: true)
                guard FileScan.isDirectory(url) else { continue }
                if matches(name, keys: keys) {
                    add(SaveSource(root: .documents, path: name), .nameMatch, at: url)
                } else if ["my games", "saved games"].contains(name.lowercased()) {
                    scan(root: .documents, parent: url, prefix: name, depth: 1)
                }
            }
        }

        // Folders inside the game's own folder that are named like saves.
        if let install = roots.install, FileScan.isDirectory(install) {
            func lookInside(_ dir: URL, prefix: String, depth: Int) {
                for name in listing(dir) ?? [] {
                    let url = dir.appendingPathComponent(name, isDirectory: true)
                    guard FileScan.isDirectory(url) else { continue }
                    let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                    if installSaveNames.contains(name.lowercased()) {
                        add(SaveSource(root: .install, path: path), .installFolder, at: url)
                    } else if depth > 1 {
                        lookInside(url, prefix: path, depth: depth - 1)
                    }
                }
            }
            lookInside(install, prefix: "", depth: 2)
        }

        return found.values.sorted {
            $0.reason.rank != $1.reason.rank ? $0.reason.rank < $1.reason.rank : $0.source.path.localizedCaseInsensitiveCompare($1.source.path) == .orderedAscending
        }
    }

    // MARK: Matching

    /// Lowercase letters and digits only.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The whole title and the part before a subtitle ("The Witcher 3: Wild Hunt" -> "The Witcher 3").
    static func nameKeys(_ title: String) -> [String] {
        var keys = [normalize(title)]
        for separator in [":", " - ", " – "] {
            if let range = title.range(of: separator) { keys.append(normalize(String(title[..<range.lowerBound]))) }
        }
        return Array(Set(keys.filter { $0.count >= 4 }))
    }

    static func matches(_ folder: String, keys: [String]) -> Bool {
        let f = normalize(folder)
        guard !f.isEmpty else { return false }
        return keys.contains { k in f == k || (min(f.count, k.count) >= 5 && (f.contains(k) || k.contains(f))) }
    }

    static func isNoise(_ name: String) -> Bool { name.hasPrefix(".") || noise.contains(name.lowercased()) }

    private static func listing(_ dir: URL) -> [String]? {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted()
    }
}
