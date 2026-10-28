import Foundation

/// Games with anti-cheat, from the community-kept list at areweanticheatyet.com (MIT licensed).
///
/// That list is about Proton on Linux. Its "Supported" and "Running" mean the developer turned on Easy Anti-Cheat's
/// or BattlEye's Linux runtime, which is a Linux library a Mac can't load, so on a Mac every entry counts as
/// blocked except those whose only anti-cheat is Valve's (VAC runs on Steam's servers, not in the game).
public enum AntiCheatList {
    public struct Entry: Codable, Equatable, Sendable {
        /// The list's status for Proton: "Supported", "Running", "Planned", "Broken" or "Denied".
        public var status: String
        public var anticheats: [String]

        public init(status: String, anticheats: [String]) {
            self.status = status
            self.anticheats = anticheats
        }
    }

    public struct Cache: Codable, Equatable, Sendable {
        public var updated: Date
        /// By Steam app ID.
        public var steam: [String: Entry]

        public init(updated: Date, steam: [String: Entry]) {
            self.updated = updated
            self.steam = steam
        }
    }

    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json")!
    public static let maxAge: TimeInterval = 24 * 3600

    /// Anti-cheat that doesn't stop a game from running under Wine on a Mac.
    static func isHarmless(_ anticheat: String) -> Bool {
        anticheat.localizedCaseInsensitiveContains("valve") || anticheat.localizedCaseInsensitiveContains("VAC")
    }

    static func parse(_ data: Data) throws -> [String: Entry] {
        guard let games = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        var result: [String: Entry] = [:]
        for game in games {
            let anticheats = game["anticheats"] as? [String] ?? []
            guard let status = game["status"] as? String, !anticheats.allSatisfy(isHarmless),
                  let ids = game["storeIds"] as? [String: Any],
                  let appID = SteamDiscover.intValue(ids["steam"]) else { continue }
            result[String(appID)] = Entry(status: status, anticheats: anticheats)
        }
        return result
    }

    public static func fetch(session: URLSession = .shared) async throws -> Cache {
        let (data, response) = try await session.data(for: URLRequest(url: sourceURL, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return Cache(updated: Date(), steam: try parse(data))
    }

    public static func load(paths: Paths) -> Cache? {
        guard let data = try? Data(contentsOf: paths.antiCheatFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    public static func save(_ cache: Cache, paths: Paths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try encoder.encode(cache).write(to: paths.antiCheatFile, options: .atomic)
    }
}

/// Whether a game the user doesn't own yet is worth buying for MaPC, in plain words.
public struct DiscoverVerdict: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable {
        /// Has a Mac version on the store.
        case macVersion
        /// Signals point to it running (Steam Deck rating).
        case likely
        /// Known not to run (anti-cheat, VR, Steam Deck "Unsupported", MaPC's own notes).
        case wontRun
    }

    public var level: Level
    public var label: String
    public var reason: String

    public init(level: Level, label: String, reason: String) {
        self.level = level
        self.label = label
        self.reason = reason
    }

    /// MaPC's own notes first, then anti-cheat and VR, then a Mac version, then the Steam Deck rating. Nil when
    /// nothing is known: no badge is better than a guess. A Deck rating alone never claims more than "likely":
    /// Deck runs Proton on Linux, not Wine on Apple silicon. Its "Unsupported" is a strong "no" though: Valve
    /// gives it for the same things that stop MaPC (anti-cheat, VR, launchers Wine can't run).
    public static func make(for item: DiscoverItem, antiCheat: [String: AntiCheatList.Entry] = [:],
                            knownIssues: [String: String] = KnownIssues.builtIn) -> DiscoverVerdict? {
        if let note = knownIssues[item.id] {
            return DiscoverVerdict(level: .wontRun, label: "Won't run", reason: note)
        }
        if item.store == .steam, let entry = antiCheat[item.storeID] {
            let names = entry.anticheats.isEmpty ? "anti-cheat" : ListFormatter.localizedString(byJoining: entry.anticheats)
            return DiscoverVerdict(level: .wontRun, label: "Won't run",
                                   reason: "It uses \(names), which needs a real Windows PC and blocks compatibility layers like the one MaPC uses.")
        }
        if item.vrOnly {
            return DiscoverVerdict(level: .wontRun, label: "Won't run", reason: "It needs a VR headset, which macOS doesn't support.")
        }
        if item.macNative {
            return DiscoverVerdict(level: .macVersion, label: "Mac version",
                                   reason: "This game also has a Mac version you can download from the store.")
        }
        switch item.deck {
        case .verified?, .playable?:
            let rating = item.deck == .verified ? "Verified" : "Playable"
            return DiscoverVerdict(level: .likely, label: "Likely to run",
                                   reason: "Steam Deck rates it \(rating). Deck plays Windows games through Wine too, so it's a good sign, though not a promise for Mac.")
        case .unsupported?:
            return DiscoverVerdict(level: .wontRun, label: "Won't run",
                                   reason: "Steam Deck marks it Unsupported, usually because of anti-cheat, VR or a launcher that doesn't run outside Windows.")
        default:
            return nil
        }
    }
}
