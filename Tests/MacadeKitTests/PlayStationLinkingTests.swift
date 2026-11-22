import Foundation
import Testing
@testable import MacadeKit

@Suite struct PlayStationLinkingTests {
    let epicHZD = Game(store: .epic, storeID: "4af7cb19d9db48878d2ffe0edc8440a2", title: "Horizon Zero Dawn Remastered", isInstalled: true)
    let steamHZD = Game(store: .steam, storeID: "2561580", title: "Horizon Zero Dawn Remastered", isInstalled: true)
    let other = Game(store: .epic, storeID: "Heather", title: "Red Dead Redemption 2", isInstalled: true)

    @Test func horizonGetsTheLinkingQRCode() {
        #expect(PlayStationLinking.arguments(for: epicHZD, userArguments: []) == ["-showlinkingqr"])
        #expect(PlayStationLinking.arguments(for: steamHZD, userArguments: ["-windowed"]) == ["-showlinkingqr"])
    }

    @Test func notAddedTwiceOrToOtherGames() {
        #expect(PlayStationLinking.arguments(for: epicHZD, userArguments: ["-ShowLinkingQR"]).isEmpty)
        #expect(PlayStationLinking.arguments(for: other, userArguments: []).isEmpty)
    }

    @Test func gamePageExplainsIt() {
        #expect(KnownIssues.note(for: epicHZD) == PlayStationLinking.note)
        #expect(KnownIssues.note(for: other) == nil)
    }
}
