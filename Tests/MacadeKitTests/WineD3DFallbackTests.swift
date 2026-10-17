import Foundation
import Testing
@testable import MacadeKit

/// A minimal PE-looking file: "MZ", padding, then the 16 bytes at 0x40 Wine uses to mark builtins.
private func dll(marker: String = "Wine builtin DLL", body: String = "wine d3d") -> Data {
    var d = Data("MZ".utf8) + Data(count: 0x3E)
    d += Data(marker.utf8.prefix(16)) + Data(count: 16 - min(16, marker.utf8.count))
    d += Data(body.utf8) + Data(count: 32)
    return d
}

@Suite struct WineD3DFallbackTests {
    @Test func recognisesWineBuildsOnly() {
        #expect(WineD3DFallback.isWineBuild(dll()))
        #expect(!WineD3DFallback.isWineBuild(dll(body: "/Sources/D3DMetalDLLsBase/d3d11.c")))  // Apple's, same marker
        #expect(!WineD3DFallback.isWineBuild(dll(marker: "")))                                  // already native
    }

    @Test func nativeCopyClearsOnlyTheMarker() {
        let original = dll()
        let native = WineD3DFallback.nativeCopy(of: original)
        #expect(native.count == original.count)
        #expect(native[0x40..<0x50].allSatisfy { $0 == 0 })
        #expect(native[..<0x40] == original[..<0x40])
        #expect(native[0x50...] == original[0x50...])
        #expect(!WineD3DFallback.isWineBuild(native))
    }

    @Test func stashKeepsWineOriginalsOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macade-stash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let windows = dir.appendingPathComponent("wine/lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        try #"{"version":"2.0.0","wineVersion":"11","backends":["d3dMetal"],"minMacOS":"14.0"}"#
            .write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        for m in ["d3d10", "d3d11", "dxgi"] { try dll(body: "wine \(m)").write(to: windows.appendingPathComponent("\(m).dll")) }
        let engine = try #require(Engine(directory: dir))

        try WineD3DFallback.stashOriginals(of: engine)
        let stash = WineD3DFallback.stash(in: engine)
        #expect(FileManager.default.contents(atPath: stash.appendingPathComponent("d3d11.dll").path) == dll(body: "wine d3d11"))

        // After D3DMetal is linked, a second call must not replace the saved originals.
        try dll(body: "D3DMetalDLLsBase").write(to: windows.appendingPathComponent("d3d11.dll"))
        try FileManager.default.removeItem(at: stash.appendingPathComponent("dxgi.dll"))
        try dll(body: "D3DMetalDLLsBase").write(to: windows.appendingPathComponent("dxgi.dll"))
        try WineD3DFallback.stashOriginals(of: engine)
        #expect(FileManager.default.contents(atPath: stash.appendingPathComponent("d3d11.dll").path) == dll(body: "wine d3d11"))
        #expect(!FileManager.default.fileExists(atPath: stash.appendingPathComponent("dxgi.dll").path))
    }

    @Test func noDXVKOverridesOnAnEngineWithoutDXVK() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macade-eng-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"version":"2.0.0","wineVersion":"11","backends":["d3dMetal"],"minMacOS":"14.0"}"#
            .write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        let engine = try #require(Engine(directory: dir))
        let bottle = Bottle(kind: .steam, paths: Paths(home: URL(fileURLWithPath: "/tmp/m")))
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), engine: engine, base: [:])
        #expect(env["WINEDLLOVERRIDES"] == "mscoree,mshtml=;winemenubuilder.exe=d")
    }
}
