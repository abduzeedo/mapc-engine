import Foundation
import Testing
@testable import MacadeKit

/// An actor so the fake writer can record from the `sync` closure.
private actor Writes {
    var calls: [String: Bool] = [:]
    func record(_ name: String, _ value: Bool) { calls[name] = value }
}

@Suite struct MacDriverTests {
    private var retinaOff: [String: Bool] {
        var p = LaunchProfile()
        p.retina = false
        return MacDriver.values(for: p)
    }

    @Test func profileValues() {
        var p = LaunchProfile()
        p.retina = true
        p.commandAsControl = true
        #expect(MacDriver.values(for: p) == ["RetinaMode": true, "LeftCommandIsCtrl": true, "RightCommandIsCtrl": true])
    }

    @Test func flagsReadLikeTheMacDriver() {
        for on in ["y", "Y", "yes", "t", "true", "1"] { #expect(MacDriver.flag(on) == true) }
        for off in ["n", "N", "no", "f", "false", "0"] { #expect(MacDriver.flag(off) == false) }
        #expect(MacDriver.flag(nil) == nil)
        #expect(MacDriver.flag("") == nil)
        #expect(MacDriver.flag("maybe") == nil)
    }

    /// The bug: the registry said y while the profile (and MaPC's record of its last write) said off.
    @Test func registryThatDriftedIsCorrected() {
        let registry = ["RetinaMode": "y", "LeftCommandIsCtrl": "n", "RightCommandIsCtrl": "n"]
        #expect(MacDriver.changes(wanted: retinaOff, registry: registry) == ["RetinaMode": false])
    }

    @Test func matchingRegistryWritesNothing() {
        let registry = ["retinamode": "N", "LeftCommandIsCtrl": "0", "RightCommandIsCtrl": "f"]   // any case, any spelling
        #expect(MacDriver.changes(wanted: retinaOff, registry: registry).isEmpty)
    }

    @Test func missingOrUnreadableValuesAreWritten() {
        #expect(MacDriver.changes(wanted: retinaOff, registry: ["RetinaMode": "n"])
                == ["LeftCommandIsCtrl": false, "RightCommandIsCtrl": false])
        #expect(MacDriver.changes(wanted: retinaOff, registry: ["RetinaMode": "auto", "LeftCommandIsCtrl": "n", "RightCommandIsCtrl": "n"])
                == ["RetinaMode": false])
        #expect(MacDriver.changes(wanted: retinaOff, registry: [:]) == retinaOff)
        #expect(MacDriver.changes(wanted: retinaOff, registry: nil) == retinaOff)   // couldn't read: write all
    }

    @Test func parsesUserReg() {
        let reg = """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        [Software\\\\Wine\\\\AppDefaults\\\\RDR2.exe\\\\Mac Driver] 1760000000
        "RetinaMode"="n"

        [Software\\\\Wine\\\\Mac Driver] 1760997003
        #time=1dc41f4b1b2c3d4
        "LeftCommandIsCtrl"="y"\r
        "RetinaMode"="y"
        "Odd \\"name\\""="a\\\\b"
        "Number"=dword:00000001

        [Software\\\\Wine\\\\X11 Driver] 1760000000
        "RetinaMode"="n"
        """
        #expect(MacDriver.parse(userReg: reg) == ["LeftCommandIsCtrl": "y", "RetinaMode": "y", #"Odd "name""#: #"a\b"#])
    }

    @Test func userRegWithoutTheKeyIsEmpty() {
        let reg = "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\AppDefaults\\\\x.exe\\\\Mac Driver] 1\n\"RetinaMode\"=\"y\"\n"
        #expect(MacDriver.parse(userReg: reg).isEmpty)
        #expect(MacDriver.parse(userReg: "").isEmpty)
    }

    @Test func parsesRegQuery() {
        let output = "\r\nHKEY_CURRENT_USER\\Software\\Wine\\Mac Driver\r\n    LeftCommandIsCtrl    REG_SZ    y\r\n    RetinaMode    REG_SZ    n\r\n    Level    REG_DWORD    0x1\r\n    Empty    REG_SZ    \r\n\r\n"
        #expect(MacDriver.parse(regQuery: output) == ["LeftCommandIsCtrl": "y", "RetinaMode": "n", "Empty": ""])
    }

    @Test func syncWritesOnlyDifferencesAndReportsFailures() async {
        let writes = Writes()
        let result = await MacDriver.sync(retinaOff, read: { ["RetinaMode": "y", "LeftCommandIsCtrl": "n"] }) { name, value in
            await writes.record(name, value)
            return name != "RightCommandIsCtrl"    // this write fails
        }
        #expect(await writes.calls == ["RetinaMode": false, "RightCommandIsCtrl": false])
        #expect(result.written == ["RetinaMode": false])
        #expect(result.failed == ["RightCommandIsCtrl": false])
        #expect(!result.succeeded)
        #expect(result.before == ["RetinaMode": "y", "LeftCommandIsCtrl": "n"])
    }

    @Test func syncWithUnreadableRegistryWritesEverything() async {
        let writes = Writes()
        let result = await MacDriver.sync(retinaOff, read: { nil }) { name, value in
            await writes.record(name, value); return true
        }
        #expect(await writes.calls == retinaOff)
        #expect(result.written == retinaOff)
        #expect(result.succeeded)
        #expect(result.before == nil)
    }

    @Test func syncInStepWritesNothing() async {
        let writes = Writes()
        let result = await MacDriver.sync(retinaOff, read: { ["RetinaMode": "n", "LeftCommandIsCtrl": "n", "RightCommandIsCtrl": "n"] }) { name, value in
            await writes.record(name, value); return true
        }
        #expect(await writes.calls.isEmpty)
        #expect(result.written.isEmpty && result.succeeded)
    }

    /// A bottle without a wineserver is read from `user.reg`, without starting anything.
    @Test func readsUserRegOfAnIdleBottle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macade-macdriver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(home: root)
        let bottle = Bottle(kind: .gog, paths: paths)
        try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        try "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\Mac Driver] 1\n\"RetinaMode\"=\"y\"\n"
            .write(to: bottle.url.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        // An engine whose wineserver doesn't exist: `-k0` fails, as it does when no wineserver runs.
        let dir = root.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        try #"{"version":"1.0.0","wineVersion":"11","backends":["dxvk"],"minMacOS":"14.0"}"#
            .write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        let engine = try #require(Engine(directory: dir))
        let runner = WineRunner(paths: paths)
        #expect(await runner.macDriverRegistry(engine: engine, bottle: bottle) == ["RetinaMode": "y"])
        try FileManager.default.removeItem(at: bottle.url.appendingPathComponent("user.reg"))
        #expect(await runner.macDriverRegistry(engine: engine, bottle: bottle) == nil)
    }
}
