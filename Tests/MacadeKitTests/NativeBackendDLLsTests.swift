import Foundation
import Testing
@testable import MacadeKit

@Suite struct NativeBackendDLLsTests {
    let fm = FileManager.default

    /// "MZ", padding, optional builtin marker at 0x40, then a body that tells the copies apart.
    func dll(_ body: String, builtin: Bool = false) -> Data {
        Data("MZ".utf8) + Data(count: 0x3E) + (builtin ? Data("Wine builtin DLL".utf8) : Data(count: 16)) + Data(body.utf8)
    }

    /// An engine with Wine's own d3d11 as the builtin and DXVK (native) and DXMT (builtin-marked) beside it,
    /// and a bottle with Wine's placeholders in system32/syswow64.
    func fixture(backends: [String] = ["dxvk", "dxmt"]) throws -> (home: URL, engine: Engine, bottle: Bottle) {
        let home = fm.temporaryDirectory.appendingPathComponent("macade-native-\(UUID().uuidString)")
        let engineDir = home.appendingPathComponent("Engines/1.1.0")
        let lib = engineDir.appendingPathComponent("wine/lib")
        try fm.createDirectory(at: engineDir.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        let json = #"{"version":"1.1.0","wineVersion":"11.18 (Staging)","backends":["#
            + backends.map { "\"\($0)\"" }.joined(separator: ",") + #"],"minMacOS":"15.0"}"#
        try json.write(to: engineDir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        func put(_ data: Data, _ path: String) throws {
            let url = lib.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for arch in ["x86_64-windows", "i386-windows"] {
            for m in ["d3d11", "d3d10core", "dxgi"] { try put(dll("wine \(m) \(arch)", builtin: true), "wine/\(arch)/\(m).dll") }
            try put(dll("winemetal \(arch)", builtin: true), "wine/\(arch)/winemetal.dll")
            for m in ["d3d11", "d3d10core"] { try put(dll("dxvk \(m) \(arch)"), "dxvk/\(arch)/\(m).dll") }
            for m in ["d3d11", "d3d10core", "dxgi"] { try put(dll("dxmt \(m) \(arch)", builtin: true), "dxmt/\(arch)/\(m).dll") }
        }
        try put(dll("nvngx"), "dxmt/x86_64-windows/nvngx.dll")   // in the folder, but not something we copy
        let paths = Paths(home: home)
        let bottle = Bottle(kind: .epic, paths: paths)
        for folder in ["system32", "syswow64"] {
            let dir = bottle.driveC.appendingPathComponent("windows/\(folder)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let arch = folder == "system32" ? "x86_64-windows" : "i386-windows"
            for m in ["d3d11", "d3d10core", "dxgi"] { try dll("wine \(m) \(arch)", builtin: true).write(to: dir.appendingPathComponent("\(m).dll")) }
        }
        return (home, try #require(Engine(directory: engineDir)), bottle)
    }

    func file(_ bottle: Bottle, _ folder: String, _ name: String) -> Data? {
        fm.contents(atPath: bottle.driveC.appendingPathComponent("windows/\(folder)/\(name)").path)
    }

    @Test func dxvkGoesInNativeForBothArchitectures() throws {
        let (home, engine, bottle) = try fixture()
        defer { try? fm.removeItem(at: home) }
        try NativeBackendDLLs.prepare(.dxvk, engine: engine, bottle: bottle)
        #expect(file(bottle, "system32", "d3d11.dll") == dll("dxvk d3d11 x86_64-windows"))
        #expect(file(bottle, "syswow64", "d3d10core.dll") == dll("dxvk d3d10core i386-windows"))
        #expect(file(bottle, "system32", "dxgi.dll") == dll("wine dxgi x86_64-windows", builtin: true))   // not DXVK's
    }

    @Test func dxmtReplacesDXVKAndGetsItsHelperPlaceholder() throws {
        let (home, engine, bottle) = try fixture()
        defer { try? fm.removeItem(at: home) }
        try NativeBackendDLLs.prepare(.dxvk, engine: engine, bottle: bottle)
        try NativeBackendDLLs.prepare(.dxmt, engine: engine, bottle: bottle)
        let d3d11 = try #require(file(bottle, "syswow64", "d3d11.dll"))
        #expect(d3d11 == NativeBackendDLLs.nativeCopy(of: dll("dxmt d3d11 i386-windows", builtin: true)))
        #expect(d3d11[0x40..<0x50].allSatisfy { $0 == 0 })                                       // loads as native
        #expect(file(bottle, "system32", "dxgi.dll") == dll("dxmt dxgi x86_64-windows"))
        #expect(file(bottle, "syswow64", "winemetal.dll") == dll("winemetal i386-windows", builtin: true))
        #expect(file(bottle, "system32", "nvngx.dll") == nil)
    }

    @Test func wineD3DAndUnprovidedBackendsLeaveTheBottleAlone() throws {
        let (home, engine, bottle) = try fixture(backends: ["dxvk"])
        defer { try? fm.removeItem(at: home) }
        for backend in [GraphicsBackend.wined3d, .d3dMetal, .dxmt] {   // DXMT's folder exists, but ENGINE.json doesn't list it
            try NativeBackendDLLs.prepare(backend, engine: engine, bottle: bottle)
        }
        #expect(file(bottle, "system32", "d3d11.dll") == dll("wine d3d11 x86_64-windows", builtin: true))
        #expect(!NativeBackendDLLs.provides(.dxmt, engine: engine))
        #expect(NativeBackendDLLs.provides(.dxvk, engine: engine))
    }

    @Test func enginesWithoutTheFolderAreLeftAlone() throws {
        // Engine 1.0.0 copied DXVK over Wine's builtins and has no lib/dxvk.
        let (home, engine, bottle) = try fixture()
        defer { try? fm.removeItem(at: home) }
        try fm.removeItem(at: NativeBackendDLLs.folder(for: .dxvk, in: engine))
        try NativeBackendDLLs.prepare(.dxvk, engine: engine, bottle: bottle)
        #expect(file(bottle, "system32", "d3d11.dll") == dll("wine d3d11 x86_64-windows", builtin: true))
    }

    @Test func switchingBackOffDXVKPutsWinesCopiesBack() throws {
        // The bug from testing: DXVK's d3d10core stayed in System32 after switching to a D3DMetal engine, and the
        // Rockstar launcher (told by WineD3DFallback to prefer native d3d10core) crashed in it.
        let (home, engine, bottle) = try fixture()
        defer { try? fm.removeItem(at: home) }
        try NativeBackendDLLs.prepare(.dxvk, engine: engine, bottle: bottle)
        let fallbackD3D11 = dll("wine d3d11, written by WineD3DFallback")
        try fallbackD3D11.write(to: bottle.driveC.appendingPathComponent("windows/system32/d3d11.dll"))
        try NativeBackendDLLs.prepare(.d3dMetal, engine: engine, bottle: bottle)
        #expect(file(bottle, "system32", "d3d10core.dll") == dll("wine d3d10core x86_64-windows", builtin: true))
        #expect(file(bottle, "syswow64", "d3d11.dll") == dll("wine d3d11 i386-windows", builtin: true))
        #expect(file(bottle, "system32", "d3d11.dll") == fallbackD3D11)                    // not ours any more
        #expect(file(bottle, "system32", NativeBackendDLLs.record) == nil)
        #expect(file(bottle, "syswow64", NativeBackendDLLs.record) == nil)
    }

    @Test func dxmtToDXVKTakesBackDXMTsDXGI() throws {
        let (home, engine, bottle) = try fixture()
        defer { try? fm.removeItem(at: home) }
        try NativeBackendDLLs.prepare(.dxmt, engine: engine, bottle: bottle)
        try NativeBackendDLLs.prepare(.dxvk, engine: engine, bottle: bottle)
        #expect(file(bottle, "system32", "dxgi.dll") == dll("wine dxgi x86_64-windows", builtin: true))
        #expect(file(bottle, "system32", "d3d11.dll") == dll("dxvk d3d11 x86_64-windows"))
        try NativeBackendDLLs.prepare(.wined3d, engine: engine, bottle: bottle)
        for folder in ["system32", "syswow64"] {
            let arch = folder == "system32" ? "x86_64-windows" : "i386-windows"
            for m in ["d3d11", "d3d10core", "dxgi"] {
                #expect(file(bottle, folder, "\(m).dll") == dll("wine \(m) \(arch)", builtin: true), "\(folder)/\(m)")
            }
        }
    }

    @Test func nativeCopyLeavesNativeDLLsUnchanged() {
        let native = dll("dxvk")
        #expect(NativeBackendDLLs.nativeCopy(of: native) == native)
        let cleared = NativeBackendDLLs.nativeCopy(of: dll("dxmt", builtin: true))
        #expect(cleared == dll("dxmt"))
    }
}
