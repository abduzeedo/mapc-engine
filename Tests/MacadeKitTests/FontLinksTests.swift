import Foundation
import Testing
@testable import MacadeKit

@Suite struct FontLinksTests {
    @Test func writesOneMultiSzValuePerFaceUnderSystemLink() {
        let commands = FontLinks.registryCommands()
        #expect(commands.count == 2)
        #expect(commands.map { $0[4] } == ["Tahoma", "Microsoft Sans Serif"])
        for command in commands {
            #expect(command.prefix(3) == ["reg", "add", FontLinks.systemLinkKey])
            #expect(command.contains("REG_MULTI_SZ") && command.last == "/f")
            #expect(command[2].hasSuffix(#"FontLink\SystemLink"#))
        }
    }

    @Test func macFontsComeFirstAndWineDefaultsStayIntact() {
        let data = FontLinks.registryCommands()[0][8]
        #expect(data.hasPrefix(#"STHeiti Medium.ttc,Heiti TC\0"#))
        let entries = data.components(separatedBy: #"\0"#)
        #expect(entries == FontLinks.macEntries + FontLinks.wineDefaults)
        #expect(FontLinks.wineDefaults.count == 9)
    }

    @Test func entriesAreFileCommaFamilyWithoutWeightWords() {
        for entry in FontLinks.macEntries + FontLinks.wineDefaults {
            #expect(entry.range(of: "^[^,]+,[^,]+$", options: .regularExpression) != nil)
            let family = entry.components(separatedBy: ",")[1]
            #expect(family.range(of: " (Medium|Light|Regular|Bold)$", options: .regularExpression) == nil)
        }
    }
}
