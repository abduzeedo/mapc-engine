import Foundation
import Testing
import MacadeKit
@testable import MapcCommand

@Suite struct ParserTests {
    @Test func noArgumentsIsHelp() throws {
        #expect(try Parser.parse([]) == .help)
        #expect(try Parser.parse(["--help"]) == .help)
    }

    @Test func runKeepsTheProgramsOwnFlags() throws {
        let cmd = try Parser.parse(["run", "--bottle", "gog", "--backend", "wined3d", "--env", "A=1", "--verbose",
                                    #"C:\Games\Caesar IV\CaesarIV.exe"#, "--windowed", "-x"])
        var o = Options()
        o.bottle = .gog; o.backend = .wined3d; o.environment = ["A": "1"]; o.verbose = true
        #expect(cmd == .run(o, program: #"C:\Games\Caesar IV\CaesarIV.exe"#, arguments: ["--windowed", "-x"]))
    }

    @Test func doubleDashEndsOptions() throws {
        #expect(try Parser.parse(["run", "--", "--odd-name.exe"]) == .run(Options(), program: "--odd-name.exe", arguments: []))
    }

    @Test func backendNamesIgnoreCase() throws {
        guard case .env(let o) = try Parser.parse(["env", "--backend", "D3DMETAL"]) else { Issue.record(); return }
        #expect(o.backend == .d3dMetal)
    }

    @Test func badInputIsRefused() {
        #expect(throws: UsageError.self) { try Parser.parse(["fly"]) }
        #expect(throws: UsageError.self) { try Parser.parse(["run"]) }
        #expect(throws: UsageError.self) { try Parser.parse(["run", "--bottle", "origin", "x.exe"]) }
        #expect(throws: UsageError.self) { try Parser.parse(["run", "--backend", "vulkan", "x.exe"]) }
        #expect(throws: UsageError.self) { try Parser.parse(["run", "--env", "notakeyvalue", "x.exe"]) }
        #expect(throws: UsageError.self) { try Parser.parse(["run", "--engine"]) }
        #expect(throws: UsageError.self) { try Parser.parse(["env", "extra"]) }
        #expect(throws: UsageError.self) { try Parser.parse(["probe"]) }
    }

    @Test func optionsBecomeALaunchProfile() {
        var o = Options()
        o.backend = .dxvk; o.hud = true; o.environment = ["DXVK_HUD": "1"]
        let p = o.profile
        #expect(p.backend == .dxvk && p.performanceHUD && !p.verboseLogs && p.extraEnvironment == ["DXVK_HUD": "1"])
    }
}

@Suite struct EngineChoiceTests {
    func engines() throws -> (root: URL, list: [Engine]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mapc-\(UUID().uuidString)")
        return (root, try ["1.0.0", "2.0.0"].map { try makeEngine(root, version: $0) })
    }

    @Test func usesTheEngineTheBottleLastRanWith() throws {
        let (root, list) = try engines(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try EngineChoice.pick(requested: nil, recorded: "1.0.0", installed: list) { list[1] }.version == "1.0.0")
    }

    @Test func requestedEngineWinsAndMustExist() throws {
        let (root, list) = try engines(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try EngineChoice.pick(requested: "2.0.0", recorded: "1.0.0", installed: list) { nil }.version == "2.0.0")
        #expect(throws: UsageError.self) { try EngineChoice.pick(requested: "9.9", recorded: nil, installed: list) { list[0] } }
    }

    @Test func otherwiseTheAppsChoice() throws {
        let (root, list) = try engines(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try EngineChoice.pick(requested: nil, recorded: "0.1", installed: list) { list[1] }.version == "2.0.0")
        #expect(throws: UsageError.self) { try EngineChoice.pick(requested: nil, recorded: nil, installed: []) { nil } }
    }

    func makeEngine(_ root: URL, version: String) throws -> Engine {
        let dir = root.appendingPathComponent(version)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        let wine = dir.appendingPathComponent("wine/bin/wine")
        try "#!/bin/sh\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try #"{"version":"\#(version)","wineVersion":"11","backends":["dxvk"],"minMacOS":"14.0"}"#
            .write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        return try #require(Engine(directory: dir))
    }
}

@Suite struct MapcEnvTests {
    @Test func envMatchesTheAppsEnvironment() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mapc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let engine = try EngineChoiceTests().makeEngine(paths.engines, version: "1.0.0")
        let (picked, profile) = try Mapc(paths: paths).resolve(Options())
        #expect(picked.version == engine.version)
        #expect(profile.backend == .dxvk)                                       // Automatic without a game folder
        let env = WineRunner.environment(bottle: Bottle(kind: .steam, paths: paths), profile: profile, engine: picked)
        #expect(env["WINEDLLOVERRIDES"]?.hasSuffix("d3d11,d3d10core=n,b") == true)
    }
}
