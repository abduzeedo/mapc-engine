import Foundation
import Testing
@testable import MacadeKit

@Suite struct AmazonParserTests {
    @Test func libraryEntriesWithArtwork() {
        let json = #"""
        [{"id":"ent-1","product":{"id":"amzn1.adg.product.abc","title":"Fallout 76","sku":"SKU1",
          "productDetail":{"iconUrl":"https://m.media-amazon.com/icon.jpg",
            "details":{"backgroundUrl1":"https://m.media-amazon.com/bg1.jpg","backgroundUrl2":"https://m.media-amazon.com/bg2.jpg"}}}},
         {"id":"ent-2","product":{"id":"amzn1.adg.product.def"}}]
        """#
        let items = AmazonParser.library(Data(json.utf8))
        #expect(items.map(\.id) == ["amzn1.adg.product.abc"])
        #expect(items.first?.cover?.absoluteString == "https://m.media-amazon.com/icon.jpg")
        #expect(items.first?.background?.absoluteString == "https://m.media-amazon.com/bg2.jpg")
        #expect(AmazonParser.sku(Data(json.utf8), id: "amzn1.adg.product.abc") == "SKU1")
    }

    @Test func installedFolders() {
        let json = #"[{"id":"amzn1.adg.product.abc","version":"v1","path":"/Users/me/Games/MaPC/Amazon/Game","size":10}]"#
        #expect(AmazonParser.installed(Data(json.utf8))["amzn1.adg.product.abc"]?.path == "/Users/me/Games/MaPC/Amazon/Game")
        #expect(AmazonParser.installed(Data()).isEmpty)
    }

    @Test func fuelMainCommand() {
        let json = "\u{FEFF}" + #"""
        {"SchemaVersion":"2","Main":{"Command":"Bin\\Game.exe","Args":["-amazon"],"WorkingSubdirOverride":"Bin",},}
        """#
        let task = AmazonParser.fuel(Data(json.utf8))
        #expect(task == GOGParser.PlayTask(path: #"Bin\Game.exe"#, arguments: ["-amazon"], workingDirectory: "Bin"))
    }

    @Test func postInstallSteps() {
        let json = #"{"SchemaVersion":"2","PostInstall":[{"Command":"dependencies\\vcredist_x86.exe","Args":["/q","/norestart"],"ValidReturns":[0,5100]}],"Main":{"Command":"Game.exe"}}"#
        #expect(AmazonParser.postInstall(Data(json.utf8)) == [.init(command: #"dependencies\vcredist_x86.exe"#, arguments: ["/q", "/norestart"], validReturns: [0, 5100])])
        #expect(AmazonParser.postInstall(Data(#"{"Main":{"Command":"Game.exe"}}"#.utf8)).isEmpty)
    }
}
