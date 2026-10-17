import Foundation
import Testing
@testable import MacadeKit

@Suite struct GameInfoTests {
    @Test func matchesTitlesAcrossStores() {
        #expect(GameInfoService.normalized("Batman™ Arkham Knight") == GameInfoService.normalized("Batman™: Arkham Knight"))
        #expect(GameInfoService.normalized("Marvel's Guardians of the Galaxy") == "marvelsguardiansofthegalaxy")
        #expect(GameInfoService.normalized("Kena: Bridge of Spirits") != GameInfoService.normalized("Kena"))
    }

    @Test func parsesSteamDetails() throws {
        let json = #"""
        {"2138710":{"success":true,"data":{"short_description":"A <b>Kung Fu</b> brawler &amp; more.",
          "developers":["Sloclap"],"publishers":["Sloclap","Kepler Interactive"],
          "release_date":{"coming_soon":false,"date":"Mar 28, 2023"},
          "genres":[{"id":"1","description":"Action"}],
          "categories":[{"id":2,"description":"Single-player"},{"id":38,"description":"Online Co-op"}],
          "controller_support":"full","metacritic":{"score":81},
          "screenshots":[{"id":0,"path_full":"https://example.com/1.jpg"}]}}}
        """#
        let info = try #require(try GameInfoService.parseDetails(Data(json.utf8), appID: "2138710"))
        #expect(info.summary == "A Kung Fu brawler & more.")
        #expect(info.developers == ["Sloclap"])
        #expect(info.releaseDate == "Mar 28, 2023")
        #expect(info.genres == ["Action"])
        #expect(info.players == [.single, .coop, .online])
        #expect(info.metacritic == 81)
        #expect(info.screenshots.count == 1)
        #expect(info.logoURL?.lastPathComponent == "logo.png")
    }

    @Test func unknownAppIsNil() throws {
        #expect(try GameInfoService.parseDetails(Data(#"{"1":{"success":false}}"#.utf8), appID: "1") == nil)
    }

    @Test func oldProfilesStillLoad() throws {
        let p = try JSONDecoder().decode(LaunchProfile.self, from: Data(#"{"backend":"dxvk","performanceHUD":true}"#.utf8))
        #expect(p.backend == .dxvk && p.performanceHUD && p.retina && p.rayTracing && !p.metalFX)
    }
}
