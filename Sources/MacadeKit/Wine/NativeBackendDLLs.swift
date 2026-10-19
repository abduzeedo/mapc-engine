import Foundation

/// DXVK and DXMT as *native* DLLs in the bottle, so the engine's builtin `d3d11`/`d3d10core`/`dxgi` stay Wine's own.
///
/// Wine's default load order takes the builtin over a native DLL in System32, so a game only gets DXVK or DXMT
/// when `GraphicsBackend.overrides` says `n,b` for it, and WineD3D (no override) really is WineD3D. Engines keep
/// the DLLs outside Wine's search path in `lib/<backend>/<arch>-windows`; engines without that folder (1.0.0, which
/// copied DXVK over Wine's builtins, and the D3DMetal engines) are left alone.
///
/// DXVK and DXMT both ship a `d3d11.dll` and a bottle has one System32, so the files for the backend being
/// launched are put there before every launch. A running game keeps the copy it already loaded.
public enum NativeBackendDLLs {
    /// Engine folder → the bottle folder Wine uses for that architecture.
    static let architectures = [("x86_64-windows", "system32"), ("i386-windows", "syswow64")]
    /// What each backend replaces. Only these are copied, never anything else from the folder.
    static let modules: [GraphicsBackend: [String]] = [
        .dxvk: ["d3d11", "d3d10core"],
        .dxmt: ["d3d11", "d3d10core", "dxgi"],
    ]
    /// Builtins the backend's DLLs load (from the engine's own `lib/wine`). The bottle only needs a placeholder copy.
    static let helpers: [GraphicsBackend: [String]] = [.dxmt: ["winemetal"]]
    static let builtinMarker = Data("Wine builtin DLL".utf8)

    static func folder(for backend: GraphicsBackend, in engine: Engine) -> URL {
        engine.wineRoot.appendingPathComponent("lib/\(backend.rawValue)", isDirectory: true)
    }

    /// True when `engine` brings `backend` as native DLLs (and so needs them in the bottle to use it).
    public static func provides(_ backend: GraphicsBackend, engine: Engine) -> Bool {
        modules[backend] != nil && engine.info.backends.contains(backend.rawValue)
            && FileManager.default.fileExists(atPath: folder(for: backend, in: engine).path)
    }

    /// Puts `backend`'s DLLs into the bottle. Does nothing for other backends or engines that don't provide it.
    /// Files already in place are not rewritten.
    public static func install(_ backend: GraphicsBackend, engine: Engine, bottle: Bottle) throws {
        guard provides(backend, engine: engine), let modules = modules[backend] else { return }
        let fm = FileManager.default
        let source = folder(for: backend, in: engine)
        for (arch, systemFolder) in architectures {
            let from = source.appendingPathComponent(arch, isDirectory: true)
            let to = bottle.driveC.appendingPathComponent("windows/\(systemFolder)", isDirectory: true)
            guard fm.fileExists(atPath: from.path), fm.fileExists(atPath: to.path) else { continue }
            for module in modules {
                guard let data = fm.contents(atPath: from.appendingPathComponent("\(module).dll").path) else { continue }
                let target = to.appendingPathComponent("\(module).dll")
                let native = nativeCopy(of: data)
                if fm.contents(atPath: target.path) != native { try native.write(to: target, options: .atomic) }
            }
            for helper in helpers[backend] ?? [] {
                let target = to.appendingPathComponent("\(helper).dll")
                let builtin = engine.wineRoot.appendingPathComponent("lib/wine/\(arch)/\(helper).dll")
                guard !fm.fileExists(atPath: target.path), let data = fm.contents(atPath: builtin.path) else { continue }
                try data.write(to: target, options: .atomic)
            }
        }
    }

    /// The DLL without Wine's builtin marker, so Wine loads it as an ordinary Windows DLL. Already-native DLLs
    /// (DXVK's native repack) come back unchanged.
    static func nativeCopy(of dll: Data) -> Data {
        guard dll.count > 0x50, dll[dll.startIndex + 0x40..<dll.startIndex + 0x50].elementsEqual(builtinMarker) else { return dll }
        var copy = dll
        copy.replaceSubrange(copy.startIndex + 0x40..<copy.startIndex + 0x50, with: Data(count: 16))
        return copy
    }
}
