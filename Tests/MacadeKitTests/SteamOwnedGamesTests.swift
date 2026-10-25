import Foundation
import Testing
@testable import MacadeKit

@Suite struct SteamOwnedGamesTests {
    /// `{"iss":"steam","sub":"76561197960287930","aud":["web:store"]}` as a JWT (signature not checked).
    let token = "eyJhbGciOiJFZERTQSJ9.eyJpc3MiOiAic3RlYW0iLCAic3ViIjogIjc2NTYxMTk3OTYwMjg3OTMwIiwgImF1ZCI6IFsid2ViOnN0b3JlIl19.c2ln"

    @Test func steamIDFromToken() {
        #expect(SteamOwnedGames.steamID(fromAccessToken: token) == "76561197960287930")
        #expect(SteamOwnedGames.steamID(fromAccessToken: "not-a-token") == nil)
        #expect(SteamOwnedGames.steamID(fromAccessToken: "a.e30.c") == nil)    // {} has no sub
    }

    @Test func tokenFromAsyncConfig() {
        let signedIn = Data(#"{"success":1,"data":{"webapi_token":"\#(token)"}}"#.utf8)
        #expect(SteamOwnedGames.token(fromAsyncConfig: signedIn) == token)
        let signedOut = Data(#"{"success":1,"data":{"webapi_token":""}}"#.utf8)
        #expect(SteamOwnedGames.token(fromAsyncConfig: signedOut) == nil)
    }

    @Test func requestCarriesTokenAndSteamID() throws {
        let url = SteamOwnedGames.requestURL(accessToken: "t", steamID: "7656")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host == "api.steampowered.com")
        #expect(items.contains(URLQueryItem(name: "access_token", value: "t")))
        #expect(items.contains(URLQueryItem(name: "steamid", value: "7656")))
        #expect(items.contains(URLQueryItem(name: "include_appinfo", value: "1")))
    }

    @Test func parsesOwnedGames() throws {
        let json = #"{"response":{"game_count":2,"games":[{"appid":268910,"name":"Cuphead","playtime_forever":12},{"appid":10,"name":" "}]}}"#
        #expect(try SteamOwnedGames.parse(Data(json.utf8)) == [
            .init(appID: "268910", name: "Cuphead"), .init(appID: "10", name: "App 10"),
        ])
        #expect(try SteamOwnedGames.parse(Data(#"{"response":{}}"#.utf8)).isEmpty)
        #expect(throws: SteamOwnedGamesError.self) { try SteamOwnedGames.parse(Data("[]".utf8)) }
    }

    @Test func mergeKeepsManifestsAndAddsUninstalled() {
        let installed = [Game(store: .steam, storeID: "268910", title: "Cuphead", isInstalled: true,
                              installPath: URL(fileURLWithPath: "/x/common/Cuphead"))]
        let owned: [SteamOwnedGames.Entry] = [
            .init(appID: "268910", name: "Cuphead"), .init(appID: "1091500", name: "Cyberpunk 2077"),
            .init(appID: "228980", name: "Steamworks Common Redistributables"), .init(appID: "1091500", name: "Duplicate"),
            .init(appID: "1070560", name: "Steam Linux Runtime"), .init(appID: "220", name: "Half-Life 2"),
        ]
        let games = SteamOwnedGames.merge(installed: installed, owned: owned)
        #expect(games.map(\.title) == ["Cuphead", "Cyberpunk 2077", "Half-Life 2"])
        #expect(games[0].isInstalled && games[0].installPath != nil)
        #expect(!games[1].isInstalled && games[1].installPath == nil)
        #expect(games[1].id == "steam:1091500")
        #expect(games[1].coverURL == SteamLibrary.artworkURL(appID: "1091500", "library_600x900.jpg"))
    }

    @Test func cacheRoundTrip() throws {
        let paths = Paths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.home) }
        #expect(SteamOwnedGames.load(paths: paths) == nil)
        let cache = SteamOwnedGames.Cache(steamID: "7656", updated: Date(timeIntervalSince1970: 1_800_000_000),
                                          games: [.init(appID: "220", name: "Half-Life 2")])
        try SteamOwnedGames.save(cache, paths: paths)
        #expect(SteamOwnedGames.load(paths: paths) == cache)
        SteamOwnedGames.remove(paths: paths)
        #expect(SteamOwnedGames.load(paths: paths) == nil)
    }
}
