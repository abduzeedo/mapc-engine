import Foundation

/// `mapc://play?game=steam%3A268910`: how a game shortcut asks MaPC to start a game.
public enum GameLink {
    public static let scheme = "mapc"

    public static func playURL(gameID: String) -> URL? {
        guard isValid(gameID) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "game", value: gameID)]
        return components.url
    }

    /// The game id in a play link, or nil for anything else.
    public static func gameID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "play",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "game" })?.value, isValid(id) else { return nil }
        return id
    }

    /// "<store>:<id>" with a known store and plain characters in the id.
    public static func isValid(_ id: String) -> Bool {
        let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, StoreKind(rawValue: String(parts[0])) != nil, !parts[1].isEmpty, parts[1].count <= 200 else { return false }
        return parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
