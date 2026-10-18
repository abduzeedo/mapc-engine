import Foundation
import Testing
@testable import MacadeKit

@Suite struct SteamRecoveryTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mapc-steam-recovery-\(UUID().uuidString)")
    var paths: Paths { Paths(home: root) }
    var steam: SteamProvider { SteamProvider(paths: paths) }
    var cef: URL { steam.bottle.steamDirectory.appendingPathComponent("bin/cef/cef.win64") }
    var helper: URL { cef.appendingPathComponent("steamwebhelper.exe") }
    var real: URL { cef.appendingPathComponent("steamwebhelper_real.exe") }
    let vendor = Data(repeating: 42, count: 600_000)
    let wrapper = Data("MZ ".utf8) + ChromiumHelperWrapper.marker

    init() throws { try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func engine(withWrapper: Bool = true) throws -> Engine {
        let dir = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"version":"test","wineVersion":"test","backends":["dxvk"],"minMacOS":"15.0"}"#
            .write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        let result = try #require(Engine(directory: dir))
        if withWrapper { try wrapper.write(to: result.steamWebHelperWrapper) }
        return result
    }
    func completeClient() throws {
        try vendor.write(to: helper)
        try Data("client".utf8).write(to: steam.bottle.steamDirectory.appendingPathComponent("steamclient64.dll"))
        try FileManager.default.createDirectory(at: steam.bottle.steamDirectory.appendingPathComponent("clientui"), withIntermediateDirectories: true)
    }

    @Test func bootstrapAndRepairAlwaysVerify() throws {
        defer { cleanup() }
        #expect(!steam.isClientReady)
        #expect(!steam.arguments().contains("-noverifyfiles"))
        try completeClient()
        #expect(steam.isClientReady)
        #expect(steam.arguments().contains("-noverifyfiles"))
        #expect(!steam.arguments(verifyFiles: true).contains("-noverifyfiles"))
        try FileManager.default.removeItem(at: helper)
        #expect(!steam.isClientReady)
        #expect(!steam.arguments().contains("-noverifyfiles"))
    }

    @Test func missingWrapperDoesNotMoveVendor() throws {
        defer { cleanup() }
        try vendor.write(to: helper)
        let engine = try engine(withWrapper: false)
        #expect(throws: (any Error).self) { try steam.ensureWebHelperWrapper(engine: engine) }
        #expect(try Data(contentsOf: helper) == vendor)
        try wrapper.write(to: engine.steamWebHelperWrapper)
        #expect(try steam.ensureWebHelperWrapper(engine: engine) == ["cef.win64"])
        #expect(try Data(contentsOf: helper) == wrapper)
        #expect(try Data(contentsOf: real) == vendor)
        #expect(try steam.ensureWebHelperWrapper(engine: engine).isEmpty)
    }

    @Test func interruptedSwapRecoversFromSavedVendor() throws {
        defer { cleanup() }
        try vendor.write(to: real)
        #expect(try steam.ensureWebHelperWrapper(engine: engine()) == ["cef.win64"])
        #expect(try Data(contentsOf: helper) == wrapper)
        #expect(try Data(contentsOf: real) == vendor)
    }

    @Test func failedBackupLeavesVendorLaunchable() throws {
        defer { cleanup() }
        try vendor.write(to: helper)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("block replacement".utf8).write(to: real.appendingPathComponent("file"))
        #expect(throws: (any Error).self) { try steam.ensureWebHelperWrapper(engine: engine()) }
        #expect(try Data(contentsOf: helper) == vendor)
    }

    @Test func legacyWrapperIsUpgradedWithoutOverwritingVendor() throws {
        defer { cleanup() }
        try Data("old wrapper".utf8).write(to: helper)
        try vendor.write(to: real)
        #expect(try steam.ensureWebHelperWrapper(engine: engine()) == ["cef.win64"])
        #expect(try Data(contentsOf: real) == vendor)
        #expect(try Data(contentsOf: helper) == wrapper)
    }

    @Test func gameArgumentsFollowAppLaunch() async throws {
        defer { cleanup() }
        let engine = try engine()
        try FileManager.default.createDirectory(at: engine.wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steam.bottle.driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: engine.wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.wine.path)
        var profile = LaunchProfile()
        profile.extraArguments = ["-dx11", "argument with spaces"]
        let process = try steam.play(Game(store: .steam, storeID: "123", title: "Test", isInstalled: true), engine: engine, profile: profile)
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let text = try String(contentsOf: process.logURL, encoding: .utf8)
        #expect(text.contains("-applaunch\n123\n-dx11\nargument with spaces\n"))
        #expect(text.contains("engine=test"))
    }
}
