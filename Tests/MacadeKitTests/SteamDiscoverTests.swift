import Foundation
import Testing
@testable import MacadeKit

@Suite struct SteamDiscoverTests {
    @Test func featuredRowsKeepOrderAndSkipPackages() throws {
        let json = #"""
        {"new_releases":{"id":"cat_newreleases","items":[{"id":20,"type":0},{"id":30,"type":1},{"id":20,"type":0},{"id":"40","type":0}]},
         "top_sellers":{"items":[{"id":50,"type":0}]},
         "specials":{"items":[]},
         "status":1}
        """#
        let rows = try SteamDiscover.parseFeatured(Data(json.utf8))
        #expect(rows[.newReleases] == ["20", "40"])
        #expect(rows[.topSellers] == ["50"])
        #expect(rows[.specials] == nil)
        #expect(rows[.comingSoon] == nil)
    }

    @Test func queueRequestCarriesToken() throws {
        let url = SteamDiscover.queueURL(accessToken: "t", country: "BR")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "access_token", value: "t")))
        let input = try #require(items.first { $0.name == "input_json" }?.value)
        #expect(input.contains(#""country_code":"BR""#))
        #expect(try SteamDiscover.parseQueue(Data(#"{"response":{"appids":[10,"20"],"exhausted":false}}"#.utf8)) == ["10", "20"])
    }

    @Test func parsesStoreItems() throws {
        let json = #"""
        {"response":{"store_items":[
          {"item_type":0,"id":1145360,"success":1,"visible":true,"name":"Hades","appid":1145360,"type":0,
           "assets":{"asset_url_format":"steam/apps/1145360/abc/${FILENAME}?t=1","library_capsule":"library_600x900.jpg","header":"header.jpg","library_hero":"library_hero.jpg"},
           "release":{"steam_release_date":1600300800},
           "platforms":{"windows":true,"mac":true,"steamos_linux":false,"steam_deck_compat_category":3},
           "basic_info":{"short_description":"Defy the god of the dead."},
           "best_purchase_option":{"formatted_final_price":"$9.99","formatted_original_price":"$24.99","discount_pct":60}},
          {"id":2,"success":1,"visible":true,"name":"Some DLC","appid":2,"type":4},
          {"id":3,"success":2,"appid":3},
          {"id":4,"success":1,"visible":true,"name":"Next Year","appid":4,"type":0,
           "release":{"is_coming_soon":true,"custom_release_date_message":"Q1 2027","coming_soon_display":"text_comingsoon"},"platforms":{"windows":true}},
          {"id":5,"success":1,"visible":true,"name":"Next Week","appid":5,"type":0,
           "release":{"steam_release_date":1793224800,"is_coming_soon":true,"coming_soon_display":"date_full"}},
          {"id":6,"success":1,"visible":true,"name":"Someday","appid":6,"type":0,
           "release":{"is_coming_soon":true,"coming_soon_display":"text_comingsoon"}},
          {"id":7,"success":1,"visible":true,"name":"Late 2026","appid":7,"type":0,
           "release":{"steam_release_date":1793224800,"is_coming_soon":true,"coming_soon_display":"date_quarter"}}
        ]}}
        """#
        let items = try SteamDiscover.parseItems(Data(json.utf8))
        #expect(items.map(\.storeID) == ["1145360", "4", "5", "6", "7"])
        let hades = items[0]
        #expect(hades.title == "Hades")
        #expect(hades.coverURL?.absoluteString == "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1145360/abc/library_600x900.jpg?t=1")
        #expect(hades.macNative && hades.deck == .verified)
        #expect(hades.price == "$9.99" && hades.originalPrice == "$24.99" && hades.discountPercent == 60)
        #expect(hades.releaseDate == Date(timeIntervalSince1970: 1_600_300_800))
        #expect(hades.summary == "Defy the god of the dead.")
        #expect(hades.storePageURL.absoluteString == "https://store.steampowered.com/app/1145360")
        let next = items[1]
        #expect(next.comingSoon == "Q1 2027")
        #expect(!next.macNative && next.deck == nil && next.price == nil)
        #expect(next.coverURL == SteamLibrary.artworkURL(appID: "4", "library_600x900.jpg"))
        #expect(items[2].comingSoon == "Oct 28, 2026")
        #expect(items[3].comingSoon == "Coming soon")
        #expect(items[4].comingSoon == "Q4 2026")
    }

    @Test func antiCheatKeepsOnlyBlockedSteamGames() throws {
        let json = #"""
        [{"name":"A","status":"Denied","anticheats":["BattlEye"],"storeIds":{"steam":"100"}},
         {"name":"B","status":"Supported","anticheats":["Easy Anti-Cheat"],"storeIds":{"steam":"200"}},
         {"name":"C","status":"Broken","anticheats":[],"storeIds":{"epic":{"namespace":"x","slug":"c"}}},
         {"name":"D","status":"Broken","anticheats":["Vanguard"],"storeIds":{"steam":"300"}},
         {"name":"E","status":"Running","anticheats":["Valve Anti-Cheat"],"storeIds":{"steam":"400"}},
         {"name":"F","status":"Running","anticheats":[],"storeIds":{"steam":"500"}}]
        """#
        let list = try AntiCheatList.parse(Data(json.utf8))
        // Proton's "Supported" relies on a Linux runtime, so on a Mac it still blocks; VAC alone doesn't.
        #expect(Set(list.keys) == ["100", "200", "300"])
        #expect(list["100"] == .init(status: "Denied", anticheats: ["BattlEye"]))
    }

    @Test func verdictPrecedence() {
        var item = DiscoverItem(store: .steam, storeID: "100", title: "A")
        item.macNative = true
        item.deck = .verified
        let blocked = ["100": AntiCheatList.Entry(status: "Denied", anticheats: ["BattlEye"])]
        // The Mac version runs without Wine, so its Windows anti-cheat doesn't matter (Warframe, say).
        #expect(DiscoverVerdict.make(for: item, antiCheat: blocked)?.level == .macVersion)
        #expect(DiscoverVerdict.make(for: item, knownIssues: ["steam:100": "No."])?.reason == "No.")
        #expect(DiscoverVerdict.make(for: item)?.level == .macVersion)
        item.macNative = false
        #expect(DiscoverVerdict.make(for: item, antiCheat: blocked)?.level == .wontRun)
        #expect(DiscoverVerdict.make(for: item)?.level == .likely)
        item.deck = .unknown
        #expect(DiscoverVerdict.make(for: item) == nil)
        item.deck = .unsupported
        #expect(DiscoverVerdict.make(for: item)?.level == .wontRun)
        item.deck = .verified
        item.vrOnly = true
        #expect(DiscoverVerdict.make(for: item)?.level == .wontRun)
    }

    @Test func searchFindsAppIDs() throws {
        let html = #"<a href="https://store.steampowered.com/app/570/Dota_2/" data-ds-appid="570" data-ds-itemkey="App_570"></a><a data-ds-appid="730"></a><a data-ds-bundleid="1" data-ds-appid="1,2"></a><a data-ds-appid="570"></a>"#
        let json = try JSONSerialization.data(withJSONObject: ["success": 1, "results_html": html, "total_count": 3] as [String: Any])
        #expect(try SteamDiscover.parseSearch(json) == ["570", "730"])
        let url = SteamDiscover.searchURL(.demos, country: "US")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "category1", value: "10")))
        #expect(items.contains(URLQueryItem(name: "deck_compatibility", value: "3")))
        // The top sellers sort leaves out free items, which every demo is.
        #expect(!items.contains { $0.name == "filter" })
        let free = try #require(URLComponents(url: SteamDiscover.searchURL(.freeToTry, country: "US"), resolvingAgainstBaseURL: false)?.queryItems)
        #expect(free.contains(URLQueryItem(name: "filter", value: "topsellers")))
        #expect(free.contains(URLQueryItem(name: "maxprice", value: "free")))
    }

    @Test func storePageAntiCheatNotice() {
        let page = """
        <div class="anticheat_section DRM_notice" >
            <div>Uses Kernel Level Anti-Cheat</div>
            <div class="anticheat_name">RICOCHET Anti-Cheat<span class="anticheat_uninstalls"></span></div>
            <div class="anticheat_name">Boot Protection<span class="anticheat_uninstalls"> - Requires both Secure Boot & TPM 2.0</span></div>
        </div>
        """
        #expect(SteamDiscover.parseAntiCheatNotice(page) == ["RICOCHET Anti-Cheat"])
        #expect(SteamDiscover.parseAntiCheatNotice("<div class=\"game_area_description\">Hades</div>").isEmpty)
        var item = DiscoverItem(store: .steam, storeID: "1", title: "A")
        item.kernelAntiCheat = ["RICOCHET Anti-Cheat"]
        #expect(DiscoverVerdict.make(for: item)?.level == .wontRun)
        item.kernelAntiCheat = []
        #expect(DiscoverVerdict.make(for: item) == nil)
    }

    @Test func parsesDemosVRAndLogos() throws {
        let json = #"""
        {"response":{"store_items":[
          {"id":7,"success":1,"visible":true,"name":"A Demo","appid":7,"type":1,
           "assets":{"asset_url_format":"steam/apps/7/h/${FILENAME}","library_logo":"logo.png"},
           "platforms":{"windows":true,"vr_support":{"vrhmd":true,"vrhmd_only":true}}}
        ]}}
        """#
        let item = try #require(try SteamDiscover.parseItems(Data(json.utf8)).first)
        #expect(item.isDemo && item.vrOnly)
        #expect(item.logoURL?.absoluteString == "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/7/h/logo.png")
        // GetItems usually lists no logo: the plain path, which older games have.
        let bare = try #require(try SteamDiscover.parseItems(Data(#"{"response":{"store_items":[{"appid":8,"name":"B","type":0}]}}"#.utf8)).first)
        #expect(bare.logoURL == SteamLibrary.artworkURL(appID: "8", "logo.png"))
    }

    @Test func feedCacheRoundTrip() throws {
        let paths = Paths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.home) }
        #expect(SteamDiscover.load(paths: paths) == nil)
        let feed = DiscoverFeed(updated: Date(timeIntervalSince1970: 1_800_000_000),
                                rows: [DiscoverRow(kind: .topSellers, items: [DiscoverItem(store: .steam, storeID: "1", title: "One")])])
        try SteamDiscover.save(feed, paths: paths)
        #expect(SteamDiscover.load(paths: paths) == feed)
    }
}
