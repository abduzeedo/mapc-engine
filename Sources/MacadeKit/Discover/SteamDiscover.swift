import Foundation

/// A game on a store's front page that the user may not own: what the Discover page shows.
public struct DiscoverItem: Codable, Hashable, Sendable, Identifiable {
    /// Steam Deck's rating. Deck runs Windows games through Proton (Wine), so a good rating hints that Wine copes.
    public enum DeckRating: Int, Codable, Sendable {
        case unknown = 0, unsupported = 1, playable = 2, verified = 3
    }

    public var store: StoreKind
    public var storeID: String
    public var title: String
    public var summary: String?
    /// Box art (Steam's `library_600x900`), then the wide store header as a fallback.
    public var coverURL: URL?
    public var headerURL: URL?
    public var heroURL: URL?
    /// Transparent title art, laid over the hero.
    public var logoURL: URL?
    public var macNative = false
    /// Needs a VR headset, which macOS can't drive.
    public var vrOnly = false
    public var isDemo = false
    /// Kernel-level anti-cheat the store page discloses ("RICOCHET Anti-Cheat"). Nil when the page wasn't read.
    public var kernelAntiCheat: [String]?
    public var deck: DeckRating?
    /// Prices as the store formats them for the user's country.
    public var price: String?
    public var originalPrice: String?
    public var discountPercent: Int?
    public var isFree = false
    public var releaseDate: Date?
    /// "Coming soon" text for unreleased games ("Q1 2027", "Coming soon").
    public var comingSoon: String?

    public var id: String { "\(store.rawValue):\(storeID)" }

    public var storePageURL: URL {
        URL(string: "https://store.steampowered.com/app/\(storeID)")!
    }

    public init(store: StoreKind, storeID: String, title: String) {
        self.store = store
        self.storeID = storeID
        self.title = title
    }
}

/// One strip of games on the Discover page.
public struct DiscoverRow: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case recommended, freeToTry, demos, newReleases, topSellers, specials, comingSoon

        public var title: String {
            switch self {
            case .recommended: "Recommended for You"
            case .freeToTry: "Free Games to Try"
            case .demos: "Demos to Try"
            case .newReleases: "New and Trending"
            case .topSellers: "Top Sellers"
            case .specials: "On Sale"
            case .comingSoon: "Coming Soon"
            }
        }
    }

    public var kind: Kind
    public var items: [DiscoverItem]
    public var id: Kind { kind }

    public init(kind: Kind, items: [DiscoverItem]) {
        self.kind = kind
        self.items = items
    }
}

public struct DiscoverFeed: Codable, Equatable, Sendable {
    public var updated: Date
    public var rows: [DiscoverRow]

    public init(updated: Date, rows: [DiscoverRow]) {
        self.updated = updated
        self.rows = rows
    }
}

/// Steam's front page rows for the Discover page.
///
/// The rows come from the store's public `featuredcategories` (no sign-in) and, when the user signed in to
/// Steam's store in MaPC, their own discovery queue. Details and art for every game come from
/// `IStoreBrowseService/GetItems` in one batch. None of this needs a Web API key; only app IDs, the
/// country and, for the queue, the user's own store token are sent.
public enum SteamDiscover {
    static let featuredURL = "https://store.steampowered.com/api/featuredcategories"
    static let queueURL = "https://api.steampowered.com/IStoreService/GetDiscoveryQueue/v1/"
    static let itemsURL = "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/"
    static let assetBase = "https://shared.akamai.steamstatic.com/store_item_assets/"
    static let searchURL = "https://store.steampowered.com/search/results/"

    /// Games shown per row.
    static let rowLength = 20
    /// Store pages read per refresh for the anti-cheat notice; each is about 200 KB.
    static let storePageChecks = 24

    // MARK: Feed

    /// Every row Steam can give. A row whose request fails is left out; only a failure of all of them throws.
    public static func fetch(accessToken: String?, country: String, session: URLSession = .shared) async throws -> DiscoverFeed {
        async let featured = try? featuredIDs(country: country, session: session)
        async let queue = signedInQueue(accessToken: accessToken, country: country, session: session)
        async let free = try? searchIDs(.freeToTry, country: country, session: session)
        async let demos = try? searchIDs(.demos, country: country, session: session)
        var ids: [DiscoverRow.Kind: [String]] = await featured ?? [:]
        if let recommended = await queue, !recommended.isEmpty { ids[.recommended] = recommended }
        if let free = await free, !free.isEmpty { ids[.freeToTry] = free }
        if let demos = await demos, !demos.isEmpty { ids[.demos] = demos }
        guard !ids.isEmpty else { throw URLError(.cannotConnectToHost) }

        let all = Array(Set(ids.values.joined()))
        var details = (try? await items(appIDs: all, country: country, session: session)) ?? [:]
        await addAntiCheatNotices(&details, ids: ids, session: session)
        let rows = DiscoverRow.Kind.allCases.compactMap { kind -> DiscoverRow? in
            let items = (ids[kind] ?? []).compactMap { details[$0] }
            return items.isEmpty ? nil : DiscoverRow(kind: kind, items: Array(items.prefix(rowLength)))
        }
        guard !rows.isEmpty else { throw URLError(.cannotParseResponse) }
        return DiscoverFeed(updated: Date(), rows: rows)
    }

    // MARK: featuredcategories

    static func featuredURL(country: String) -> URL {
        var c = URLComponents(string: featuredURL)!
        c.queryItems = [.init(name: "cc", value: country), .init(name: "l", value: "english")]
        return c.url!
    }

    static func featuredIDs(country: String, session: URLSession) async throws -> [DiscoverRow.Kind: [String]] {
        let (data, response) = try await session.data(for: URLRequest(url: featuredURL(country: country), timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parseFeatured(data)
    }

    /// App IDs per row from `featuredcategories`, in Steam's order, without repeats. Packages and bundles
    /// (non-zero `type`) are skipped: Discover lists games.
    static func parseFeatured(_ data: Data) throws -> [DiscoverRow.Kind: [String]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let sections: [(String, DiscoverRow.Kind)] = [
            ("new_releases", .newReleases), ("top_sellers", .topSellers), ("specials", .specials), ("coming_soon", .comingSoon),
        ]
        var result: [DiscoverRow.Kind: [String]] = [:]
        for (key, kind) in sections {
            let items = (root[key] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            let ids = items.compactMap { item -> String? in
                guard (item["type"] as? Int ?? 0) == 0, let id = intValue(item["id"]) else { return nil }
                return seen.insert(String(id)).inserted ? String(id) : nil
            }
            if !ids.isEmpty { result[kind] = ids }
        }
        return result
    }

    // MARK: Store search

    /// Free games and demos that Steam Deck rates Verified, most popular first. Deck plays Windows games through
    /// Wine too, so these are the safest picks for someone trying MaPC for the first time.
    static func searchURL(_ kind: DiscoverRow.Kind, country: String) -> URL {
        var c = URLComponents(string: searchURL)!
        var items: [URLQueryItem] = [
            .init(name: "query", value: ""), .init(name: "start", value: "0"), .init(name: "count", value: "50"),
            .init(name: "infinite", value: "1"), .init(name: "deck_compatibility", value: "3"),
            .init(name: "cc", value: country), .init(name: "l", value: "english"),
        ]
        switch kind {
        // The top sellers sort leaves out free items, so demos keep the store's default order.
        case .demos: items.append(.init(name: "category1", value: "10"))
        default: items += [.init(name: "category1", value: "998"), .init(name: "maxprice", value: "free"),
                           .init(name: "filter", value: "topsellers")]
        }
        c.queryItems = items
        return c.url!
    }

    static func searchIDs(_ kind: DiscoverRow.Kind, country: String, session: URLSession) async throws -> [String] {
        let (data, response) = try await session.data(for: URLRequest(url: searchURL(kind, country: country), timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try parseSearch(data)
    }

    /// App IDs from a store search page (`infinite=1` answers JSON with the rows as HTML). Bundles carry
    /// several IDs in one attribute and are skipped.
    static func parseSearch(_ data: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let html = root["results_html"] as? String else { throw URLError(.cannotParseResponse) }
        let pattern = try NSRegularExpression(pattern: #"data-ds-appid="(\d+)""#)
        var seen = Set<String>()
        return pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            let id = String(html[range])
            return seen.insert(id).inserted ? id : nil
        }
    }

    // MARK: Anti-cheat notices

    /// Steam requires store pages to say when a game uses kernel-level anti-cheat. Read for the first games of
    /// each row that have no Mac version and no Steam Deck rating (a new Call of Duty, say): the others are
    /// covered by Deck's rating or don't need Wine. A page that can't be read just leaves no note.
    static func addAntiCheatNotices(_ details: inout [String: DiscoverItem], ids: [DiscoverRow.Kind: [String]],
                                    session: URLSession) async {
        var seen = Set<String>()
        let unrated = DiscoverRow.Kind.allCases.flatMap { (ids[$0] ?? []).prefix(10) }.filter { id in
            guard let item = details[id], !item.macNative, !item.vrOnly, item.deck == nil || item.deck == .unknown else { return false }
            return seen.insert(id).inserted
        }.prefix(storePageChecks)
        let width = 6
        let ids = Array(unrated)
        for start in stride(from: 0, to: ids.count, by: width) {
            await withTaskGroup(of: (String, [String]?).self) { group in
                for id in ids[start..<min(start + width, ids.count)] {
                    group.addTask { (id, try? await kernelAntiCheat(appID: id, session: session)) }
                }
                for await (id, names) in group { if let names { details[id]?.kernelAntiCheat = names } }
            }
        }
    }

    static func kernelAntiCheat(appID: String, session: URLSession) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://store.steampowered.com/app/\(appID)/?l=english")!, timeoutInterval: 20)
        // Past the age gate, which would otherwise answer instead of the page.
        request.setValue("birthtime=0; lastagecheckage=1-0-1990; wants_mature_content=1", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return parseAntiCheatNotice(String(decoding: data, as: UTF8.self))
    }

    /// The anti-cheat names from a store page's kernel-level anti-cheat notice; empty when there's none.
    static func parseAntiCheatNotice(_ html: String) -> [String] {
        guard let start = html.range(of: "anticheat_section") else { return [] }
        let section = String(html[start.upperBound...].prefix(2000))
        guard section.range(of: "Kernel Level", options: .caseInsensitive) != nil else { return [] }
        let pattern = try! NSRegularExpression(pattern: #"class="anticheat_name">([^<]+)"#)
        let names = pattern.matches(in: section, range: NSRange(section.startIndex..., in: section)).compactMap {
            Range($0.range(at: 1), in: section).map { section[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty && $0 != "Boot Protection" }
        return names.isEmpty ? ["kernel-level anti-cheat"] : names
    }

    // MARK: Discovery queue

    static func queueURL(accessToken: String, country: String) -> URL {
        let input: [String: Any] = ["queue_type": 0, "country_code": country, "rebuild_queue": false]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: input, options: .sortedKeys), as: UTF8.self)
        var c = URLComponents(string: queueURL)!
        c.queryItems = [.init(name: "access_token", value: accessToken), .init(name: "input_json", value: json)]
        return c.url!
    }

    /// Nil when signed out or when Steam won't give the queue for this token.
    static func signedInQueue(accessToken: String?, country: String, session: URLSession) async -> [String]? {
        guard let accessToken else { return nil }
        return try? await discoveryQueue(accessToken: accessToken, country: country, session: session)
    }

    /// The signed-in user's discovery queue: Steam's own picks for them.
    static func discoveryQueue(accessToken: String, country: String, session: URLSession) async throws -> [String] {
        let (data, response) = try await session.data(for: URLRequest(url: queueURL(accessToken: accessToken, country: country),
                                                                      timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        return try parseQueue(data)
    }

    static func parseQueue(_ data: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return (response["appids"] as? [Any] ?? []).compactMap(intValue).map(String.init)
    }

    // MARK: GetItems

    static func itemsURL(appIDs: [String], country: String) -> URL {
        let input: [String: Any] = [
            "ids": appIDs.compactMap(Int.init).map { ["appid": $0] },
            "context": ["language": "english", "country_code": country],
            "data_request": [
                "include_assets": true, "include_release": true, "include_platforms": true,
                "include_basic_info": true, "include_all_purchase_options": true,
            ],
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: input, options: .sortedKeys), as: UTF8.self)
        var c = URLComponents(string: itemsURL)!
        c.queryItems = [.init(name: "input_json", value: json)]
        return c.url!
    }

    /// Details for every app, 50 per request.
    static func items(appIDs: [String], country: String, session: URLSession) async throws -> [String: DiscoverItem] {
        var result: [String: DiscoverItem] = [:]
        for start in stride(from: 0, to: appIDs.count, by: 50) {
            let chunk = Array(appIDs[start..<min(start + 50, appIDs.count)])
            let (data, response) = try await session.data(for: URLRequest(url: itemsURL(appIDs: chunk, country: country),
                                                                          timeoutInterval: 20))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            for item in try parseItems(data) { result[item.storeID] = item }
        }
        return result
    }

    /// Games and demos from a GetItems answer. Hidden items, failed lookups and anything else (DLC, software,
    /// soundtracks: Steam's `type` other than 0 or 1) are left out.
    static func parseItems(_ data: Data) throws -> [DiscoverItem] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return (response["store_items"] as? [[String: Any]] ?? []).compactMap(parseItem)
    }

    static func parseItem(_ item: [String: Any]) -> DiscoverItem? {
        guard let id = intValue(item["appid"]) ?? intValue(item["id"]),
              intValue(item["success"]) ?? 1 == 1, item["visible"] as? Bool ?? true,
              [0, 1].contains(intValue(item["type"]) ?? 0),
              let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        var result = DiscoverItem(store: .steam, storeID: String(id), title: name)
        result.isDemo = intValue(item["type"]) == 1

        if let assets = item["assets"] as? [String: Any], let format = assets["asset_url_format"] as? String,
           format.contains("${FILENAME}") {
            func url(_ key: String) -> URL? {
                guard let file = assets[key] as? String, !file.isEmpty else { return nil }
                return URL(string: assetBase + format.replacingOccurrences(of: "${FILENAME}", with: file))
            }
            result.coverURL = url("library_capsule_2x") ?? url("library_capsule")
            result.headerURL = url("header") ?? url("main_capsule")
            result.heroURL = url("library_hero") ?? url("page_background")
            result.logoURL = url("library_logo_2x") ?? url("library_logo")
        }
        // Older games have no library art in GetItems; Steam still serves it at the plain path.
        if result.coverURL == nil { result.coverURL = SteamLibrary.artworkURL(appID: result.storeID, "library_600x900.jpg") }
        if result.headerURL == nil { result.headerURL = SteamLibrary.artworkURL(appID: result.storeID, "header.jpg") }
        // GetItems doesn't list the logo; older games still have one at the plain path (newer ones fall back to the title).
        if result.logoURL == nil { result.logoURL = SteamLibrary.artworkURL(appID: result.storeID, "logo.png") }

        if let platforms = item["platforms"] as? [String: Any] {
            result.macNative = platforms["mac"] as? Bool ?? false
            result.deck = intValue(platforms["steam_deck_compat_category"]).flatMap(DiscoverItem.DeckRating.init)
            let vr = platforms["vr_support"] as? [String: Any] ?? [:]
            result.vrOnly = vr["vrhmd_only"] as? Bool ?? vr["vr_only"] as? Bool ?? false
        }
        if let release = item["release"] as? [String: Any] {
            if let seconds = intValue(release["steam_release_date"]) ?? intValue(release["original_release_date"]), seconds > 0 {
                result.releaseDate = Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            if release["is_coming_soon"] as? Bool == true {
                result.comingSoon = comingSoonText(release, date: result.releaseDate)
            }
        }
        if let info = item["basic_info"] as? [String: Any], let summary = info["short_description"] as? String, !summary.isEmpty {
            result.summary = summary
        }
        result.isFree = item["is_free"] as? Bool ?? false
        let purchase = item["best_purchase_option"] as? [String: Any]
            ?? (item["purchase_options"] as? [[String: Any]])?.first
        if let purchase {
            result.price = purchase["formatted_final_price"] as? String
            result.discountPercent = intValue(purchase["discount_pct"]).flatMap { $0 > 0 ? $0 : nil }
            if result.discountPercent != nil { result.originalPrice = purchase["formatted_original_price"] as? String }
        }
        return result
    }

    /// When an unreleased game comes out, as the store page words it. `coming_soon_display` is a format token
    /// (`date_full`, `date_month`, `date_quarter`, `date_year`, `text_comingsoon`), not text; the text itself, when the
    /// developer wrote one, is `custom_release_date_message`.
    static func comingSoonText(_ release: [String: Any], date: Date?) -> String {
        if let message = (release["custom_release_date_message"] as? String)?.trimmingCharacters(in: .whitespaces), !message.isEmpty {
            return message
        }
        guard let date else { return "Coming soon" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 0, month = parts.month ?? 1
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        switch release["coming_soon_display"] as? String {
        case "date_year": return String(year)
        case "date_quarter": return "Q\((month - 1) / 3 + 1) \(year)"
        case "date_month": formatter.dateFormat = "MMMM yyyy"
        default: formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }

    /// Steam sends 64-bit numbers as strings in some answers.
    static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    // MARK: Cache

    public static func load(paths: Paths) -> DiscoverFeed? {
        guard let data = try? Data(contentsOf: paths.discoverFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DiscoverFeed.self, from: data)
    }

    public static func save(_ feed: DiscoverFeed, paths: Paths) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try encoder.encode(feed).write(to: paths.discoverFile, options: .atomic)
    }
}
