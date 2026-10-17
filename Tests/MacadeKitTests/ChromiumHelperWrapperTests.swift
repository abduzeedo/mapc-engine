import Foundation
import Testing
@testable import MacadeKit

@Suite struct ChromiumHelperWrapperTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macade-wrap-\(UUID().uuidString)")
    var helper: URL { dir.appendingPathComponent("SocialClubHelper.exe") }
    var real: URL { dir.appendingPathComponent("SocialClubHelper_real.exe") }
    let vendor = Data("MZ vendor chromium".utf8)
    let wrapper = Data("MZ wrapper ".utf8) + ChromiumHelperWrapper.marker

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    @Test func wrapsVendorBinaryOnce() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try vendor.write(to: helper)
        #expect(try ChromiumHelperWrapper.wrap(helper, with: wrapper))
        #expect(FileManager.default.contents(atPath: helper.path) == wrapper)
        #expect(FileManager.default.contents(atPath: real.path) == vendor)
        // Second launch: already wrapped, the vendor binary must not be overwritten by the wrapper.
        #expect(try !ChromiumHelperWrapper.wrap(helper, with: wrapper))
        #expect(FileManager.default.contents(atPath: real.path) == vendor)
    }

    @Test func refreshesAnOlderWrapperWithoutTouchingTheRealBinary() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try (Data("MZ old ".utf8) + ChromiumHelperWrapper.marker).write(to: helper)
        try vendor.write(to: real)
        #expect(try ChromiumHelperWrapper.wrap(helper, with: wrapper))
        #expect(FileManager.default.contents(atPath: helper.path) == wrapper)
        #expect(FileManager.default.contents(atPath: real.path) == vendor)
    }

    @Test func vendorUpdateReplacesTheSavedBinary() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try vendor.write(to: real)
        let updated = Data("MZ vendor chromium v2".utf8)
        try updated.write(to: helper)   // Social Club's installer put its helper back
        #expect(try ChromiumHelperWrapper.wrap(helper, with: wrapper))
        #expect(FileManager.default.contents(atPath: real.path) == updated)
    }

    @Test func missingHelperIsLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try !ChromiumHelperWrapper.wrap(helper, with: wrapper))
        #expect(!FileManager.default.fileExists(atPath: helper.path))
    }

    @Test func picksTheAppsWrapperThenAGenericEngineWrapper() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"version":"1.0.0","wineVersion":"11","backends":["dxvk"],"minMacOS":"14.0"}"#
            .write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        let engine = try #require(Engine(directory: dir))
        let bundled = dir.appendingPathComponent("chromium-helper-wrapper.exe")
        try Data("MZ steamwebhelper_real.exe only".utf8).write(to: engine.steamWebHelperWrapper)  // published engine 1.0.0
        #expect(ChromiumHelperWrapper.wrapper(in: engine, bundled: nil) == nil)
        try wrapper.write(to: bundled)
        #expect(ChromiumHelperWrapper.wrapper(in: engine, bundled: bundled) == wrapper)
        let newer = Data("MZ engine ".utf8) + ChromiumHelperWrapper.marker
        try newer.write(to: engine.steamWebHelperWrapper)
        #expect(ChromiumHelperWrapper.wrapper(in: engine, bundled: nil) == newer)
        #expect(ChromiumHelperWrapper.wrapper(in: engine, bundled: bundled) == wrapper)
    }
}
