import Foundation
import Testing
@testable import MacadeKit

/// A fake toolkit tree laid out like Apple's disk image (`redist/lib/...`).
private struct FakeToolkit {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("macade-gptk-\(UUID().uuidString)")
    var lib: URL { root.appendingPathComponent("redist/lib") }

    init(modules: [String] = ["d3d11", "d3d12", "dxgi", "nvapi64"]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: lib.appendingPathComponent("external/D3DMetal.framework"), withIntermediateDirectories: true)
        try fm.createDirectory(at: lib.appendingPathComponent("wine/x86_64-windows"), withIntermediateDirectories: true)
        try Data("not apple".utf8).write(to: lib.appendingPathComponent("external/libd3dshared.dylib"))
        for m in modules { try Data("MZ".utf8).write(to: lib.appendingPathComponent("wine/x86_64-windows/\(m).dll")) }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct D3DMetalTests {
    @Test func findsTheEvaluationImageInsideApplesDownload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macade-gptk3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(D3DMetalStore.nestedImage(in: dir) == nil)
        // Game Porting Toolkit 3.0's disk, as Apple ships it.
        for name in ["Metal Shader Converter 3.0.pkg", "Another Tool.dmg", "Evaluation environment for Windows games 3.0.dmg"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        #expect(D3DMetalStore.nestedImage(in: dir)?.lastPathComponent == "Evaluation environment for Windows games 3.0.dmg")
    }

    @Test func locatesLibFolderAtAnyReasonableDepth() throws {
        let kit = try FakeToolkit()
        defer { kit.cleanup() }
        #expect(D3DMetalStore.locate(in: kit.root)?.standardizedFileURL == kit.lib.standardizedFileURL)
        #expect(D3DMetalStore.locate(in: kit.lib)?.standardizedFileURL == kit.lib.standardizedFileURL)
        #expect(D3DMetalStore.locate(in: kit.root.appendingPathComponent("redist"))?.standardizedFileURL == kit.lib.standardizedFileURL)
    }

    @Test func rejectsFoldersWithoutD3DMetal() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("macade-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(D3DMetalStore.locate(in: empty) == nil)
    }

    @Test func appleSignatureCheck() throws {
        #expect(D3DMetalStore.isSignedByApple(URL(fileURLWithPath: "/usr/bin/true")))
        let kit = try FakeToolkit()
        defer { kit.cleanup() }
        #expect(!D3DMetalStore.isSignedByApple(kit.lib.appendingPathComponent("external/libd3dshared.dylib")))
    }

    @Test func refusesUnsignedD3DMetalAndLeavesNothingBehind() async throws {
        let kit = try FakeToolkit()
        defer { kit.cleanup() }
        let home = kit.root.appendingPathComponent("home")
        let store = D3DMetalStore(paths: Paths(home: home))
        await #expect(throws: D3DMetalError.notSignedByApple("D3DMetal.framework")) { try await store.stage(from: kit.root) }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        #expect(leftovers.isEmpty)
        #expect(store.installed == nil)
    }

    @Test func requiresTheCoreModules() async throws {
        let kit = try FakeToolkit(modules: ["d3d11", "dxgi"])
        defer { kit.cleanup() }
        let store = D3DMetalStore(paths: Paths(home: kit.root.appendingPathComponent("home")))
        await #expect(throws: D3DMetalError.missingModule("d3d12.dll")) { try await store.stage(from: kit.root) }
    }

    @Test func onlyCrossOverEnginesUseIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macade-e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, backends) in [("dx12", #"["d3dMetal"]"#), ("dxvk", #"["dxvk"]"#)] {
            let e = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: e, withIntermediateDirectories: true)
            try #"{"version":"\#(name)","wineVersion":"x","backends":\#(backends),"minMacOS":"15.0"}"#
                .write(to: e.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        }
        #expect(D3DMetalStore.canUse(try #require(Engine(directory: dir.appendingPathComponent("dx12")))))
        #expect(!D3DMetalStore.canUse(try #require(Engine(directory: dir.appendingPathComponent("dxvk")))))
    }

    /// Opt-in: imports real D3DMetal from a Game Porting Toolkit disk image or folder and links it into a copy
    /// of an installed engine. `MACADE_GPTK=/path/to/toolkit.dmg MACADE_GPTK_ENGINE=/path/to/engine swift test`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACADE_GPTK"] != nil))
    func importsRealToolkit() async throws {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-gptk-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let store = D3DMetalStore(paths: paths)
        let staged = try await store.stage(from: URL(fileURLWithPath: try #require(env["MACADE_GPTK"])))
        #expect(staged.info.version != "unknown")

        var engines: [Engine] = []
        if let source = env["MACADE_GPTK_ENGINE"] {
            let copy = paths.engines.appendingPathComponent("test")
            try FileManager.default.createDirectory(at: paths.engines, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
            try? FileManager.default.removeItem(at: copy.appendingPathComponent("wine/lib/external"))
            engines = [try #require(Engine(directory: copy))]
            #expect(!engines[0].supports(.d3dMetal))
        }
        try store.commit(staged, engines: engines)
        #expect(store.installed?.version == staged.info.version)
        for engine in engines {
            #expect(engine.supports(.d3dMetal))
            #expect(D3DMetalStore.isSignedByApple(engine.wineRoot.appendingPathComponent("lib/external/D3DMetal.framework")))
            let so = engine.wineRoot.appendingPathComponent("lib/wine/x86_64-unix/d3d12.so").path
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: so) == "../../external/libd3dshared.dylib")
        }
    }
}
