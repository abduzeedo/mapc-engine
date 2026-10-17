import Foundation

/// Parsers for GOG's web API, gogdl's output and the `goggame-<id>.info` files GOG games ship with.
public enum GOGParser {
    /// One owned product from `embed.gog.com/account/getFilteredProducts`.
    struct Product: Decodable {
        struct WorksOn: Decodable { let Windows: Bool? }
        let id: Int
        let title: String
        let isGame: Bool?
        let worksOn: WorksOn?
    }

    struct ProductsPage: Decodable {
        let totalPages: Int?
        let products: [Product]
    }

    /// Owned Windows games on one page of the library, plus the page count.
    static func products(_ data: Data) throws -> (games: [(id: String, title: String)], totalPages: Int) {
        let page = try JSONDecoder().decode(ProductsPage.self, from: data)
        let games = page.products
            .filter { $0.isGame != false && $0.worksOn?.Windows != false }
            .map { (id: String($0.id), title: $0.title) }
        return (games, page.totalPages ?? 1)
    }

    /// Art from `gamesdb.gog.com/platforms/gog/external_releases/<id>`.
    public struct Artwork: Codable, Equatable, Sendable {
        public var cover: URL?
        public var background: URL?
        public var logo: URL?
    }

    static func artwork(_ data: Data) -> Artwork {
        struct Release: Decodable {
            struct Image: Decodable { let url_format: String? }
            struct GameData: Decodable { let vertical_cover: Image?; let background: Image?; let logo: Image? }
            let game: GameData?
        }
        guard let game = (try? JSONDecoder().decode(Release.self, from: data))?.game else { return Artwork() }
        func url(_ image: Release.Image?) -> URL? {
            guard let format = image?.url_format else { return nil }
            return URL(string: format.replacingOccurrences(of: "{formatter}", with: "").replacingOccurrences(of: "{ext}", with: "jpg"))
        }
        return Artwork(cover: url(game.vertical_cover), background: url(game.background), logo: url(game.logo))
    }

    /// The token gogdl prints for `auth` (refreshed when needed).
    struct Credentials: Decodable {
        let access_token: String?
        let user_id: String?
        let error: Bool?
    }

    static func credentials(_ data: Data) -> Credentials? {
        guard let c = try? JSONDecoder().decode(Credentials.self, from: data), c.error != true, c.access_token != nil else { return nil }
        return c
    }

    /// gogdl's progress line, e.g. `[PROGRESS] INFO: = Progress: 12.34 1048576/8388608, Running for 00:00:10, ETA: ...`.
    public static func progress(from line: String) -> Double? {
        guard let range = line.range(of: "= Progress: ") else { return nil }
        let number = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(number).map { min(1, max(0, $0 / 100)) }
    }

    /// What starts a GOG game: the primary play task in `goggame-<id>.info`. When the primary task is
    /// only a launcher (Mafia: Definitive Edition's is a .NET program, and the bottle has no Mono) the
    /// game's own executable, listed as a `game` task, starts instead.
    public struct PlayTask: Equatable, Sendable {
        public var path: String
        public var arguments: [String]
        public var workingDirectory: String?
    }

    public static func playTask(infoJSON: Data) -> PlayTask? {
        struct Info: Decodable {
            struct Task: Decodable {
                let isPrimary: Bool?
                let category: String?
                let type: String?
                let path: String?
                let arguments: String?
                let workingDir: String?
            }
            let playTasks: [Task]?
        }
        guard let tasks = (try? JSONDecoder().decode(Info.self, from: infoJSON))?.playTasks else { return nil }
        let files = tasks.filter { ($0.type ?? "FileTask") == "FileTask" && $0.path != nil }
        var primary = files.first(where: { $0.isPrimary == true }) ?? files.first
        if primary?.category == "launcher", let game = files.first(where: { $0.category == "game" }) { primary = game }
        guard let task = primary, let path = task.path else { return nil }
        return PlayTask(path: path, arguments: LaunchProfile.parseArguments(task.arguments ?? ""),
                        workingDirectory: task.workingDir.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Games Macade installed from GOG (gogdl doesn't keep a list). Stored as `gog/installed.json`.
public struct GOGInstalled: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var title: String
        public var path: URL
    }
    public var games: [String: Entry] = [:]
    public init() {}
}
