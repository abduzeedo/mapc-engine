import Foundation

/// Decoders for `legendary list --json` and `legendary list-installed --json`.
struct LegendaryListEntry: Decodable {
    struct Metadata: Decodable {
        struct KeyImage: Decodable { let type: String; let url: String }
        struct Category: Decodable { let path: String? }
        /// One of Epic's `customAttributes`, `{"type": "STRING", "value": "…"}`. A value that isn't text is left out.
        struct Attribute: Decodable {
            let value: String?
            init(from decoder: Decoder) throws {
                let c = try? decoder.container(keyedBy: CodingKeys.self)
                value = try? c?.decodeIfPresent(String.self, forKey: .value)
            }
            enum CodingKeys: String, CodingKey { case value }
        }
        let keyImages: [KeyImage]?
        let categories: [Category]?
        let customAttributes: [String: Attribute]?
    }
    let app_name: String
    let app_title: String
    let metadata: Metadata?

    /// Unreal Engine content from Fab (materials, plugins, sample projects) is listed with the games.
    var isEngineAsset: Bool { metadata?.categories?.contains { $0.path == "asset-format" } == true }

    /// Ubisoft games sold on Epic still run through Ubisoft Connect. Epic marks them the way legendary reads them:
    /// `ThirdPartyManagedApp` (or `ThirdPartyManagedProvider`) is Ubisoft Connect, or `partnerLinkType` is `ubisoft`.
    /// The Epic launcher installs Ubisoft Connect for them as a prerequisite; legendary does that only on Windows.
    var needsUbisoftConnect: Bool {
        let attributes = metadata?.customAttributes ?? [:]
        let thirdParty = [attributes["ThirdPartyManagedApp"]?.value, attributes["ThirdPartyManagedProvider"]?.value]
            .compactMap { $0?.lowercased().replacingOccurrences(of: " ", with: "") }
        return thirdParty.contains { $0.contains("ubisoft") || $0.contains("uplay") }
            || attributes["partnerLinkType"]?.value?.lowercased() == "ubisoft"
    }
}

struct LegendaryInstalledEntry: Decodable {
    let app_name: String
    let title: String?
    let install_path: String
    let install_size: Int64?
    let version: String?
}

public enum LegendaryParser {
    public static func games(listJSON: Data, installedJSON: Data) throws -> [Game] {
        let decoder = JSONDecoder()
        let owned = try decoder.decode([LegendaryListEntry].self, from: listJSON)
        let installed = Dictionary(
            uniqueKeysWithValues: try decoder.decode([LegendaryInstalledEntry].self, from: installedJSON).map { ($0.app_name, $0) })

        func image(_ e: LegendaryListEntry, _ types: [String]) -> URL? {
            for t in types { if let u = e.metadata?.keyImages?.first(where: { $0.type == t })?.url { return URL(string: u) } }
            return nil
        }
        return owned.filter { !$0.isEngineAsset }.map { e in
            let inst = installed[e.app_name]
            return Game(
                store: .epic, storeID: e.app_name, title: e.app_title, isInstalled: inst != nil,
                installPath: inst.map { URL(fileURLWithPath: $0.install_path) },
                sizeOnDisk: inst?.install_size,
                coverURL: image(e, ["DieselGameBoxTall", "Thumbnail"]),
                heroURL: image(e, ["DieselGameBox", "OfferImageWide"]),
                requiredLauncher: e.needsUbisoftConnect ? .ubisoft : nil)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Parses legendary's download progress line, e.g. `[DLManager] INFO: = Progress: 12.34% (123/1000), Running for ...`.
    public static func progress(from line: String) -> Double? {
        guard let range = line.range(of: "Progress: ") else { return nil }
        let rest = line[range.upperBound...]
        guard let pct = rest.split(separator: "%").first, let value = Double(pct) else { return nil }
        return min(1, max(0, value / 100))
    }

    /// legendary's download status block, printed every second: the `= Progress:` line and the ` - Downloaded:`,
    /// ` - Cache usage:`, ` + Download` and ` + Disk` lines under it. Logs leave these out.
    public static func isProgressDetail(_ line: String) -> Bool {
        guard let range = line.range(of: "[DLManager] INFO: ") else { return false }
        let rest = line[range.upperBound...]
        return rest.hasPrefix("= Progress") || rest.hasPrefix(" - ") || rest.hasPrefix(" + ")
    }
}
