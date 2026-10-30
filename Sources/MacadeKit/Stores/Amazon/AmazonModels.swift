import Foundation

/// Parsers for Nile's `library.json` and `installed.json` and the `fuel.json` Amazon games ship with.
public enum AmazonParser {
    private struct Entitlement: Decodable {
        struct Product: Decodable {
            struct Detail: Decodable {
                struct Details: Decodable {
                    let backgroundUrl1: String?
                    let backgroundUrl2: String?
                    let logoUrl: String?
                }
                let iconUrl: String?
                let details: Details?
            }
            let id: String
            let title: String?
            let sku: String?
            let productDetail: Detail?
        }
        let product: Product
    }

    public struct Item: Equatable, Sendable {
        public var id: String
        public var title: String
        public var cover: URL?
        public var background: URL?
    }

    /// Owned games; entries without a title (not synced yet) are skipped.
    public static func library(_ data: Data) -> [Item] {
        let entries = (try? JSONDecoder().decode([Entitlement].self, from: data)) ?? []
        return entries.compactMap { e in
            guard let title = e.product.title, !title.isEmpty else { return nil }
            let detail = e.product.productDetail
            return Item(id: e.product.id, title: title,
                        cover: detail?.iconUrl.flatMap(URL.init(string:)),
                        background: (detail?.details?.backgroundUrl2 ?? detail?.details?.backgroundUrl1).flatMap(URL.init(string:)))
        }
    }

    static func sku(_ data: Data, id: String) -> String? {
        ((try? JSONDecoder().decode([Entitlement].self, from: data)) ?? []).first { $0.product.id == id }?.product.sku
    }

    /// Install folders by game id.
    public static func installed(_ data: Data) -> [String: URL] {
        struct Entry: Decodable { let id: String; let path: String }
        let entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        return Dictionary(entries.map { ($0.id, URL(fileURLWithPath: $0.path, isDirectory: true)) }, uniquingKeysWith: { a, _ in a })
    }

    /// A step `fuel.json` runs once after install, usually a bundled runtime installer (Fatal Fury Special's
    /// Visual C++ runtime). Without it some games crash at start.
    public struct PostInstallStep: Equatable, Sendable {
        public var command: String
        public var arguments: [String]
        public var validReturns: [Int32]
    }

    public static func postInstall(_ data: Data) -> [PostInstallStep] {
        struct Fuel: Decodable {
            struct Step: Decodable { let Command: String; let Args: [String]?; let ValidReturns: [Int32]? }
            let PostInstall: [Step]?
        }
        guard let steps = (try? JSONDecoder().decode(Fuel.self, from: cleaned(data)))?.PostInstall else { return [] }
        return steps.map { PostInstallStep(command: $0.Command, arguments: $0.Args ?? [], validReturns: $0.ValidReturns ?? [0]) }
    }

    /// What starts an Amazon game: `Main` in `fuel.json`. Nile reads it as JSON5; the files seen so far are
    /// plain JSON, and a BOM or trailing comma isn't worth a JSON5 parser.
    public static func fuel(_ data: Data) -> GOGParser.PlayTask? {
        struct Fuel: Decodable {
            struct Main: Decodable {
                let Command: String
                let Args: [String]?
                let WorkingSubdirOverride: String?
            }
            let Main: Main
        }
        guard let main = (try? JSONDecoder().decode(Fuel.self, from: cleaned(data)))?.Main else { return nil }
        return GOGParser.PlayTask(path: main.Command, arguments: main.Args ?? [],
                                  workingDirectory: main.WorkingSubdirOverride.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func cleaned(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return Data(text.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression).utf8)
    }
}
