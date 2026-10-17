import Testing
@testable import MacadeKit

@Suite struct EngineLabelTests {
    private func info(_ wine: String) -> EngineInfo {
        EngineInfo(version: "2.0.1", wineVersion: wine, backends: ["d3dMetal"], minMacOS: "14.0")
    }

    @Test func crossOverSourceIsAttributionNotAProduct() {
        #expect(info("11.0 (CrossOver 26.3.0)").wineDescription == "11.0, from CrossOver 26.3.0 source")
    }

    @Test func otherLabelsAreShownAsIs() {
        #expect(info("11.18 (Staging)").wineDescription == "11.18 (Staging)")
        #expect(info("11.0, from CrossOver 26.3.0 source").wineDescription == "11.0, from CrossOver 26.3.0 source")
    }
}
