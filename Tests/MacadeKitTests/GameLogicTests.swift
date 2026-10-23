import Foundation
import Testing
@testable import MacadeKit

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct LaunchEnvironmentTests {
    let paths = Paths(home: URL(fileURLWithPath: "/tmp/m"))
    var bottle: Bottle { Bottle(kind: .steam, paths: paths) }
    let host = ["HOME": "/Users/x", "PATH": "/usr/bin", "CLAUDE_CODE_FOO": "leak", "LANG": "en_US.UTF-8"]

    @Test func defaultProfileSnapshot() {
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), base: host)
        #expect(env == [
            "HOME": "/Users/x", "PATH": "/usr/bin", "LANG": "en_US.UTF-8",
            "WINEPREFIX": "/tmp/m/Bottles/steam",
            "WINEDEBUG": "-all,err+module", "MVK_CONFIG_LOG_LEVEL": "1",
            "WINEESYNC": "1", "WINEMSYNC": "1", "ROSETTA_ADVERTISE_AVX": "1",
            "WINEDLLOVERRIDES": "mscoree,mshtml=;winemenubuilder.exe=d;d3d11,d3d10core=n,b",
            "DXVK_ASYNC": "1", "MVK_CONFIG_RESUME_LOST_DEVICE": "1",
            "CX_REPORT_REAL_USERNAME": "1",
        ])
    }

    @Test func realUserNameOnEveryBackend() {
        for backend in GraphicsBackend.allCases {
            var p = LaunchProfile()
            p.backend = backend
            #expect(WineRunner.environment(bottle: bottle, profile: p, base: [:])["CX_REPORT_REAL_USERNAME"] == "1")
        }
    }

    @Test func hostEnvironmentDoesNotLeak() {
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), base: host)
        #expect(env["CLAUDE_CODE_FOO"] == nil)
    }

    @Test func hudVerboseAndUserEnvWin() {
        var p = LaunchProfile()
        p.performanceHUD = true
        p.verboseLogs = true
        p.extraEnvironment = ["DXVK_ASYNC": "0", "MY_VAR": "1"]
        let env = WineRunner.environment(bottle: bottle, profile: p, base: [:])
        #expect(env["MTL_HUD_ENABLED"] == "1")
        #expect(env["WINEDEBUG"] == "err+all,warn+module")
        #expect(env["MVK_CONFIG_LOG_LEVEL"] == nil)    // MoltenVK's own default (info) for verbose logs
        #expect(env["DXVK_ASYNC"] == "0")          // user settings merged last
        #expect(env["MY_VAR"] == "1")
    }

    @Test func wined3dAddsNoOverrides() {
        var p = LaunchProfile()
        p.backend = .wined3d
        let env = WineRunner.environment(bottle: bottle, profile: p, base: [:])
        #expect(env["WINEDLLOVERRIDES"] == "mscoree,mshtml=;winemenubuilder.exe=d")
        #expect(env["DXVK_ASYNC"] == nil)
    }

    @Test func extraOverridesAreAppended() {
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), base: [:], extraOverrides: ["bcrypt=b;ncrypt=b"])
        #expect(env["WINEDLLOVERRIDES"]?.hasSuffix(";bcrypt=b;ncrypt=b") == true)
    }

    @Test func autoPicksD3DMetalOnlyForDirectX12Games() {
        let dx12 = GraphicsProbe(usesDirectX12: true, has64BitExecutable: true)
        let dx11 = GraphicsProbe(usesDirectX12: false, has64BitExecutable: true)
        #expect(GraphicsBackend.auto.resolved() == .dxvk)
        #expect(GraphicsBackend.auto.resolved(for: dx12, d3dMetalAvailable: true) == .d3dMetal)
        #expect(GraphicsBackend.auto.resolved(for: dx12, d3dMetalAvailable: false) == .dxvk)
        #expect(GraphicsBackend.auto.resolved(for: dx11, d3dMetalAvailable: true) == .dxvk)   // verified games keep DXVK
        #expect(GraphicsBackend.auto.resolved(for: nil, d3dMetalAvailable: true) == .dxvk)
        #expect(GraphicsBackend.dxvk.resolved(for: dx12, d3dMetalAvailable: true) == .dxvk)   // the user's choice wins
        let d3d11x86 = GraphicsProbe(uses32BitDirect3D11: true)
        #expect(GraphicsBackend.auto.resolved(for: d3d11x86, dxmtAvailable: true) == .dxmt)
        #expect(GraphicsBackend.auto.resolved(for: d3d11x86, dxmtAvailable: false) == .dxvk)
        #expect(GraphicsBackend.auto.resolved(for: dx11, dxmtAvailable: true) == .dxvk)
    }

    @Test func d3dMetalGetsCrossOverVariablesFromItsEngine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeTestEngine(root, version: "2.0.0", backends: ["d3dMetal"], d3dMetal: true)
        var p = LaunchProfile()
        p.backend = .d3dMetal
        let env = WineRunner.environment(bottle: bottle, profile: p, engine: engine, base: [:])
        #expect(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == engine.wineRoot.appendingPathComponent("lib/external/libd3dshared.dylib").path)
        #expect(env["CX_ACTIVE_GRAPHICS_BACKEND"] == "d3dmetal")
        #expect(env["D3DM_SUPPORT_DXR"] == "1")
        #expect(env["WINEDLLOVERRIDES"] == "mscoree,mshtml=;winemenubuilder.exe=d")     // D3DMetal DLLs are builtins
        #expect(env["DXVK_ASYNC"] == nil)

        p.backend = .dxvk                                                                // same engine, other backend
        #expect(WineRunner.environment(bottle: bottle, profile: p, engine: engine, base: [:])["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == nil)
    }
}

@Suite struct SteamLibraryTests {
    @Test func parsesInstalledGame() throws {
        let text = String(decoding: try fixtureData("appmanifest_268910.acf"), as: UTF8.self)
        let game = try #require(SteamLibrary.parseManifest(text, steamapps: URL(fileURLWithPath: "/s/steamapps")))
        #expect(game.id == "steam:268910")
        #expect(game.title == "Cuphead")
        #expect(game.isInstalled)
        #expect(game.installProgress == nil)
        #expect(game.installPath?.path == "/s/steamapps/common/Cuphead")
        #expect(game.sizeOnDisk == 4_044_947_883)
        #expect(game.coverURL?.absoluteString.hasSuffix("/268910/library_600x900.jpg") == true)
    }

    @Test func downloadingGameShowsProgress() throws {
        let acf = #""AppState" { "appid" "42" "name" "Big" "StateFlags" "1026" "installdir" "Big" "BytesToDownload" "1000" "BytesDownloaded" "250" }"#
        let game = try #require(SteamLibrary.parseManifest(acf, steamapps: URL(fileURLWithPath: "/s")))
        #expect(!game.isInstalled)
        #expect(game.installProgress == 0.25)
    }

    @Test func ignoresToolsAndRedistributables() {
        let redist = #""AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "StateFlags" "4" }"#
        let proton = #""AppState" { "appid" "1" "name" "Proton 9.0" "StateFlags" "4" }"#
        #expect(SteamLibrary.parseManifest(redist, steamapps: URL(fileURLWithPath: "/s")) == nil)
        #expect(SteamLibrary.parseManifest(proton, steamapps: URL(fileURLWithPath: "/s")) == nil)
        #expect(SteamLibrary.parseManifest("garbage {", steamapps: URL(fileURLWithPath: "/s")) == nil)
    }

    @Test func scansABottleAcrossLibraryFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: home))
        let main = bottle.steamDirectory.appendingPathComponent("steamapps")
        let second = bottle.driveC.appendingPathComponent("Games2/steamapps")
        for d in [main, second] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try #"""
        "libraryfolders" { "0" { "path" "C:\\Program Files (x86)\\Steam" } "1" { "path" "C:\\Games2" } "2" { "path" "D:\\Elsewhere" } }
        """#.write(to: main.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "1" "name" "Beta" "StateFlags" "4" "installdir" "Beta" }"#
            .write(to: main.appendingPathComponent("appmanifest_1.acf"), atomically: true, encoding: .utf8)
        try #""AppState" { "appid" "2" "name" "alpha" "StateFlags" "4" "installdir" "Alpha" }"#
            .write(to: second.appendingPathComponent("appmanifest_2.acf"), atomically: true, encoding: .utf8)
        let games = SteamLibrary.scan(bottle: bottle)
        #expect(games.map(\.title) == ["alpha", "Beta"])
    }

    @Test func windowsPathMapping() {
        let bottle = Bottle(kind: .steam, paths: Paths(home: URL(fileURLWithPath: "/h")))
        #expect(bottle.unixURL(forWindowsPath: #"C:\Program Files (x86)\Steam"#)?.path == "/h/Bottles/steam/drive_c/Program Files (x86)/Steam")
        #expect(bottle.unixURL(forWindowsPath: #"D:\x"#) == nil)
    }

    @Test func otherDrivesFollowDosdevices() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: home))
        let dosdevices = bottle.url.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dosdevices.appendingPathComponent("z:").path, withDestinationPath: "/")
        try FileManager.default.createSymbolicLink(atPath: dosdevices.appendingPathComponent("e:").path, withDestinationPath: "../drive_c/games")
        #expect(bottle.unixURL(forWindowsPath: #"Z:\Volumes\SSD\SteamLibrary"#)?.path == "/Volumes/SSD/SteamLibrary")
        #expect(bottle.unixURL(forWindowsPath: #"e:\x"#)?.path == bottle.driveC.appendingPathComponent("games/x").standardizedFileURL.path)
        #expect(bottle.unixURL(forWindowsPath: #"D:\x"#) == nil)
        #expect(bottle.unixURL(forWindowsPath: "Steam") == nil)
    }
}

@Suite struct LegendaryParserTests {
    @Test func mapsLibraryAndInstalledState() throws {
        let games = try LegendaryParser.games(listJSON: try fixtureData("legendary-list.json"),
                                              installedJSON: try fixtureData("legendary-installed.json"))
        #expect(games.map(\.title) == ["alpha Game", "No Metadata", "Zed Game"])
        let zed = try #require(games.last)
        #expect(zed.id == "epic:abc123")
        #expect(zed.isInstalled)
        #expect(zed.installPath?.path == "/Users/x/Games/Macade/Epic/Zed")
        #expect(zed.coverURL?.absoluteString == "https://cdn.example/tall.jpg")
        #expect(zed.heroURL?.absoluteString == "https://cdn.example/wide.jpg")
        #expect(games[0].isInstalled == false && games[0].coverURL == nil)
    }

    @Test func parsesProgressLines() {
        #expect(LegendaryParser.progress(from: "[DLManager] INFO: = Progress: 12.50% (125/1000), Running for 00:00:10, ETA: 00:01:10") == 0.125)
        #expect(LegendaryParser.progress(from: "[DLManager] INFO: = Progress: 100.00% (1/1)") == 1)
        #expect(LegendaryParser.progress(from: "[cli] INFO: something else") == nil)
    }
}

@Suite struct EngineTests {
    func makeEngine(_ root: URL, version: String, backends: [String], bundle: Bool) throws {
        let dir = root.appendingPathComponent("Engines/\(version)")
        let wine = bundle ? dir.appendingPathComponent("Wine.app/Contents/Resources/wine") : dir.appendingPathComponent("wine")
        try FileManager.default.createDirectory(at: wine.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let bin = wine.appendingPathComponent("bin/wine")
        try "#!/bin/sh".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let json = #"{"version":"\#(version)","wineVersion":"11","backends":[\#(backends.map { "\"\($0)\"" }.joined(separator: ","))],"minMacOS":"15.0"}"#
        try json.write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
    }

    @Test func locatesEnginesBackendsAndBundleLayout() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeEngine(home, version: "1.0.0-dxvk", backends: ["dxvk"], bundle: true)
        try makeEngine(home, version: "1.10.0-dxmt", backends: ["dxmt"], bundle: false)
        let locator = EngineLocator(paths: Paths(home: home))
        #expect(locator.installed().map(\.version) == ["1.10.0-dxmt", "1.0.0-dxvk"])   // numeric ordering
        #expect(locator.engine(for: .dxvk)?.version == "1.0.0-dxvk")
        #expect(locator.engine(for: .auto)?.version == "1.10.0-dxmt")
        #expect(locator.engine(for: .d3dMetal)?.version == "1.10.0-dxmt")           // falls back to newest
        #expect(locator.engine(for: .dxvk)?.wine.path.hasSuffix("Wine.app/Contents/Resources/wine/bin/wine") == true)
    }

    @Test func d3dMetalNeedsAppleBridgeInTheEngine() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeTestEngine(home, version: "1.0.0", backends: ["dxvk"], d3dMetal: false)
        let broken = try makeTestEngine(home, version: "3.0.0", backends: ["d3dMetal"], d3dMetal: false)
        let good = try makeTestEngine(home, version: "2.0.0", backends: ["d3dMetal"], d3dMetal: true)
        #expect(!broken.supports(.d3dMetal))                                              // claims it, file missing
        #expect(good.supports(.d3dMetal))
        #expect(good.d3dMetalLibrary != nil && broken.d3dMetalLibrary == nil)
        let locator = EngineLocator(paths: Paths(home: home))
        #expect(locator.engine(for: .d3dMetal, activeVersion: "1.0.0")?.version == "2.0.0")
        #expect(locator.engine(for: .dxvk, activeVersion: "1.0.0")?.version == "1.0.0")
    }

    @Test func emptyHomeHasNoEngine() {
        let locator = EngineLocator(paths: Paths(home: URL(fileURLWithPath: "/nonexistent-macade")))
        #expect(locator.engine(for: .auto) == nil)
    }
}

@Suite struct KnownIssuesTests {
    @Test func builtInAndRemoteNotes() {
        let fortnite = Game(store: .epic, storeID: "Fortnite", title: "Fortnite", isInstalled: false)
        let other = Game(store: .steam, storeID: "1", title: "Other", isInstalled: true)
        #expect(KnownIssues.note(for: fortnite)?.contains("anti-cheat") == true)
        #expect(KnownIssues.note(for: other) == nil)
        #expect(KnownIssues.note(for: other, remote: ["steam:1": "Needs a patch"]) == "Needs a patch")
        #expect(KnownIssues.note(for: fortnite, remote: ["epic:Fortnite": "Custom"]) == "Custom")
    }

    @Test func directX12NoteOnlyWithoutD3DMetal() {
        let witcher = Game(store: .steam, storeID: "292030", title: "The Witcher 3", isInstalled: true)
        let dx12 = GraphicsProbe(usesDirectX12: true, has64BitExecutable: true)
        #expect(KnownIssues.note(for: witcher, probe: dx12, d3dMetalAvailable: false) == KnownIssues.needsDirectX12Engine)
        #expect(KnownIssues.note(for: witcher, probe: dx12, d3dMetalAvailable: true) == nil)
        #expect(KnownIssues.note(for: witcher, probe: GraphicsProbe(), d3dMetalAvailable: false) == nil)
        #expect(KnownIssues.note(for: witcher) == nil)                                    // not probed yet
        let d3d11x86 = GraphicsProbe(uses32BitDirect3D11: true)
        #expect(KnownIssues.note(for: witcher, probe: d3d11x86) == KnownIssues.needs32BitDirect3D11Engine)
        #expect(KnownIssues.note(for: witcher, probe: d3d11x86, dxmtAvailable: true) == nil)
    }
}

@Suite struct ProfileParsingTests {
    @Test func parsesEnvironmentLines() {
        let env = LaunchProfile.parseEnvironment("""
        # comment
        DXVK_HUD=fps
        BAD LINE
          MY_VAR = a=b
        =novalue
        1-BAD=x
        """)
        #expect(env == ["DXVK_HUD": "fps", "MY_VAR": "a=b"])
        #expect(LaunchProfile.parseEnvironment(LaunchProfile.formatEnvironment(env)) == env)
    }

    @Test func parsesArguments() {
        #expect(LaunchProfile.parseArguments(#"-windowed  -name "Two Words" -x"#) == ["-windowed", "-name", "Two Words", "-x"])
        #expect(LaunchProfile.parseArguments("   ").isEmpty)
    }
}

/// A fake installed engine under `<root>/Engines/<version>` (plain `wine/` layout).
@discardableResult
func makeTestEngine(_ root: URL, version: String, backends: [String], d3dMetal: Bool) throws -> Engine {
    let dir = root.appendingPathComponent("Engines/\(version)")
    let wine = dir.appendingPathComponent("wine")
    try FileManager.default.createDirectory(at: wine.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let bin = wine.appendingPathComponent("bin/wine")
    try "#!/bin/sh".write(to: bin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    if d3dMetal {
        let external = wine.appendingPathComponent("lib/external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data().write(to: external.appendingPathComponent("libd3dshared.dylib"))
    }
    let list = backends.map { "\"\($0)\"" }.joined(separator: ",")
    try #"{"version":"\#(version)","wineVersion":"11","backends":[\#(list)],"minMacOS":"14.0"}"#
        .write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
    return try #require(Engine(directory: dir))
}
