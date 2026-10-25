import Foundation

public enum SteamOwnedGamesError: Error, LocalizedError {
    case badToken
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .badToken: "Steam didn't return a usable sign-in. Please sign in again."
        case .failed(let m): m
        }
    }
}

/// Every game a Steam account owns, installed or not. Steam only writes app manifests for installed games,
/// so `SteamLibrary.scan` alone never lists the rest.
///
/// The list comes from Valve's Web API (`IPlayerService/GetOwnedGames`) with the access token of the user's own
/// Steam store session: the app signs in to Steam's website in a web view and reads the token from it. Unlike
/// a Web API key this works with private profiles. The token is only used for the request and never stored;
/// the list is cached so it outlives the token (about a day).
public enum SteamOwnedGames {
    public struct Entry: Codable, Hashable, Sendable {
        public let appID: String
        public let name: String

        public init(appID: String, name: String) {
            self.appID = appID
            self.name = name
        }
    }

    public struct Cache: Codable, Equatable, Sendable {
        public var steamID: String
        public var updated: Date
        public var games: [Entry]

        public init(steamID: String, updated: Date, games: [Entry]) {
            self.steamID = steamID
            self.updated = updated
            self.games = games
        }
    }

    /// Steam's store hands its signed-in pages a Web API token here (`data.webapi_token`).
    public static let tokenURL = URL(string: "https://store.steampowered.com/pointssummary/ajaxgetasyncconfig")!

    // MARK: Token

    /// The SteamID64 an access token belongs to: the `sub` claim of the JWT.
    public static func steamID(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = claims["sub"] as? String, sub.count == 17, sub.allSatisfy(\.isNumber) else { return nil }
        return sub
    }

    /// The token from `tokenURL`'s answer, nil when signed out (Steam then leaves it empty).
    public static func token(fromAsyncConfig data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (root["data"] as? [String: Any])?["webapi_token"] as? String,
              steamID(fromAccessToken: token) != nil else { return nil }
        return token
    }

    // MARK: Owned games

    public static func requestURL(accessToken: String, steamID: String) -> URL {
        var c = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!
        c.queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "include_played_free_games", value: "1"),
        ]
        return c.url!
    }

    /// Parses GetOwnedGames. An account with no games answers `{"response":{}}`.
    public static func parse(_ data: Data) throws -> [Entry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else {
            throw SteamOwnedGamesError.failed("Steam sent an unexpected answer for your library.")
        }
        let games = response["games"] as? [[String: Any]] ?? []
        return games.compactMap { game in
            guard let id = game["appid"] as? Int else { return nil }
            let name = (game["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Entry(appID: String(id), name: name.isEmpty ? "App \(id)" : name)
        }
    }

    /// Reads the account's owned games with a store session's access token.
    public static func fetch(accessToken: String) async throws -> Cache {
        guard let steamID = steamID(fromAccessToken: accessToken) else { throw SteamOwnedGamesError.badToken }
        let (data, response) = try await URLSession.shared.data(from: requestURL(accessToken: accessToken, steamID: steamID))
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return Cache(steamID: steamID, updated: Date(), games: try parse(data))
        case 401, 403: throw SteamOwnedGamesError.badToken
        default: throw SteamOwnedGamesError.failed("Couldn't read your Steam library.")
        }
    }

    // MARK: Cache

    public static func load(paths: Paths) -> Cache? {
        guard let data = try? Data(contentsOf: paths.steamOwnedFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    public static func save(_ cache: Cache, paths: Paths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try encoder.encode(cache).write(to: paths.steamOwnedFile, options: .atomic)
    }

    public static func remove(paths: Paths) {
        try? FileManager.default.removeItem(at: paths.steamOwnedFile)
    }

    // MARK: Library

    /// The bottle's games plus the owned games that aren't installed. Manifests win: they know the install
    /// state, path and size, and they also list games the signed-in account doesn't own (family sharing,
    /// another account in Steam).
    public static func merge(installed: [Game], owned: [Entry]) -> [Game] {
        var seen = Set(installed.map(\.storeID))
        let missing = owned.compactMap { entry -> Game? in
            guard seen.insert(entry.appID).inserted,
                  !SteamLibrary.ignoredAppIDs.contains(entry.appID),
                  !SteamLibrary.ignoredNamePrefixes.contains(where: { entry.name.hasPrefix($0) }) else { return nil }
            return Game(store: .steam, storeID: entry.appID, title: entry.name, isInstalled: false,
                        coverURL: SteamLibrary.artworkURL(appID: entry.appID, "library_600x900.jpg"),
                        heroURL: SteamLibrary.artworkURL(appID: entry.appID, "library_hero.jpg"))
        }
        return (installed + missing).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
