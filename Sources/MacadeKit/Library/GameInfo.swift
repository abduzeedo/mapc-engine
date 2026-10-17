import Foundation

/// What a game's store page says about it: shown on the game page.
public struct GameInfo: Codable, Equatable, Sendable {
    public enum PlayerMode: String, Codable, Sendable, CaseIterable {
        case single, multi, coop, online

        public var displayName: String {
            switch self {
            case .single: "Single-player"
            case .multi: "Multiplayer"
            case .coop: "Co-op"
            case .online: "Online"
            }
        }
    }

    public var steamAppID: String?
    public var summary: String?
    public var developers: [String] = []
    public var publishers: [String] = []
    public var releaseDate: String?
    public var genres: [String] = []
    public var players: [PlayerMode] = []
    /// "full" or "partial" controller support, as Steam reports it.
    public var controllerSupport: String?
    public var metacritic: Int?
    public var screenshots: [URL] = []
    /// Transparent title artwork (Steam's `logo.png`), for the game page header.
    public var logoURL: URL?
    /// Wide artwork for games whose store has none (Steam's `library_hero.jpg`).
    public var heroURL: URL?
    /// Box art for games whose store gives none (Steam's `library_600x900.jpg`).
    public var coverURL: URL?
    public var fetched = Date()

    public init() {}
}

/// Fetches `GameInfo` from Steam's public store API and caches it on disk. Epic games are matched to
/// their Steam page by exact title; a game with no exact match gets only what its own store knows.
/// Only game titles and Steam app IDs are sent; nothing about the user.
public actor GameInfoService {
    private let directory: URL
    private let session: URLSession
    private var memory: [String: GameInfo] = [:]
    private static let maxAge: TimeInterval = 30 * 24 * 3600

    public init(paths: Paths, session: URLSession = .shared) {
        self.directory = paths.home.appendingPathComponent("GameInfo", isDirectory: true)
        self.session = session
    }

    /// Cached info right away (possibly stale), without touching the network.
    public func cached(for game: Game) -> GameInfo? {
        if let hit = memory[game.id] { return hit }
        guard let data = try? Data(contentsOf: file(for: game)),
              let info = try? Self.decoder.decode(GameInfo.self, from: data) else { return nil }
        memory[game.id] = info
        return info
    }

    public func info(for game: Game) async -> GameInfo? {
        if let hit = cached(for: game), Date().timeIntervalSince(hit.fetched) < Self.maxAge { return hit }
        var info: GameInfo?
        do {
            let appID = game.store == .steam ? game.storeID : try await steamAppID(matching: game.title)
            if let appID { info = try await details(appID: appID) }
        } catch {
            return cached(for: game)       // offline: keep what we had
        }
        var result = info ?? GameInfo()
        result.fetched = Date()
        memory[game.id] = result
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Self.encoder.encode(result).write(to: file(for: game), options: .atomic)
        return result
    }

    // MARK: Steam store API

    func steamAppID(matching title: String) async throws -> String? {
        var c = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        c.queryItems = [.init(name: "term", value: title), .init(name: "cc", value: "us"), .init(name: "l", value: "en")]
        let (data, _) = try await session.data(from: c.url!)
        struct Search: Decodable { struct Item: Decodable { let id: Int; let name: String }; let items: [Item] }
        let items = try JSONDecoder().decode(Search.self, from: data).items
        let wanted = Self.normalized(title)
        return items.first { Self.normalized($0.name) == wanted }.map { String($0.id) }
    }

    func details(appID: String) async throws -> GameInfo? {
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english")!
        let (data, _) = try await session.data(from: url)
        return try Self.parseDetails(data, appID: appID)
    }

    static func parseDetails(_ data: Data, appID: String) throws -> GameInfo? {
        struct Envelope: Decodable { let success: Bool; let data: Details? }
        struct Named: Decodable { let id: FlexibleID?; let description: String }
        struct Details: Decodable {
            let short_description: String?
            let developers: [String]?
            let publishers: [String]?
            let release_date: Release?
            let genres: [Named]?
            let categories: [Named]?
            let controller_support: String?
            let metacritic: Meta?
            let screenshots: [Shot]?
            struct Release: Decodable { let date: String? }
            struct Meta: Decodable { let score: Int? }
            struct Shot: Decodable { let path_full: String }
        }
        let envelope = try JSONDecoder().decode([String: Envelope].self, from: data)[appID]
        guard let envelope, envelope.success, let d = envelope.data else { return nil }

        var info = GameInfo()
        info.steamAppID = appID
        info.summary = d.short_description.map(Self.plainText).flatMap { $0.isEmpty ? nil : $0 }
        info.developers = d.developers ?? []
        info.publishers = d.publishers ?? []
        info.releaseDate = d.release_date?.date.flatMap { $0.isEmpty ? nil : $0 }
        info.genres = (d.genres ?? []).map(\.description)
        // Steam category ids: 2 single-player, 1 multi-player, 9 co-op, 36/38 online PvP/co-op.
        let ids = Set((d.categories ?? []).compactMap { $0.id?.value })
        var players: [GameInfo.PlayerMode] = []
        if ids.contains(2) { players.append(.single) }
        if ids.contains(1) || ids.contains(49) { players.append(.multi) }
        if !ids.isDisjoint(with: [9, 38, 39]) { players.append(.coop) }
        if !ids.isDisjoint(with: [36, 38]) { players.append(.online) }
        info.players = players
        info.controllerSupport = d.controller_support
        info.metacritic = d.metacritic?.score
        info.screenshots = (d.screenshots ?? []).prefix(8).compactMap { URL(string: $0.path_full) }
        info.logoURL = SteamLibrary.artworkURL(appID: appID, "logo.png")
        info.heroURL = SteamLibrary.artworkURL(appID: appID, "library_hero.jpg")
        info.coverURL = SteamLibrary.artworkURL(appID: appID, "library_600x900.jpg")
        return info
    }

    /// Steam sends ids as numbers; tolerate strings.
    struct FlexibleID: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = i } else { value = Int(try c.decode(String.self)) ?? -1 }
        }
    }

    // MARK: Helpers

    static func normalized(_ title: String) -> String {
        let stripped = title.lowercased().replacingOccurrences(of: "&", with: "and")
        return String(stripped.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func file(for game: Game) -> URL {
        directory.appendingPathComponent(game.id.replacingOccurrences(of: ":", with: "-") + ".json")
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
