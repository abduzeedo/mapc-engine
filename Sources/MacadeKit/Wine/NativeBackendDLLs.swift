import CryptoKit
import Foundation

/// DXVK and DXMT as *native* DLLs in the bottle, so the engine's builtin `d3d11`/`d3d10core`/`dxgi` stay Wine's own.
///
/// Wine's default load order takes the builtin over a native DLL in System32, so a game only gets DXVK or DXMT
/// when `GraphicsBackend.overrides` says `n,b` for it, and WineD3D (no override) really is WineD3D. Engines keep
/// the DLLs outside Wine's search path in `lib/<backend>/<arch>-windows`; engines without that folder (1.0.0, which
/// copied DXVK over Wine's builtins, and the D3DMetal engines) provide neither.
///
/// DXVK and DXMT both ship a `d3d11.dll` and a bottle has one System32, so `prepare` runs before every launch: it
/// puts the launched backend's DLLs there and takes back the ones an earlier launch put there that this one doesn't
/// want. That matters beyond overrides: `WineD3DFallback` tells the Rockstar launcher to prefer native Direct3D
/// DLLs, and a DXVK `d3d10core` left from a DXVK launch crashes it under D3DMetal. A running game keeps the copy it
/// already loaded.
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
    /// In each system folder: module → SHA-256 of the copy we put there, so we only ever take back our own files.
    static let record = ".macade-native-backend"

    static func folder(for backend: GraphicsBackend, in engine: Engine) -> URL {
        engine.wineRoot.appendingPathComponent("lib/\(backend.rawValue)", isDirectory: true)
    }

    /// True when `engine` brings `backend` as native DLLs (and so needs them in the bottle to use it).
    public static func provides(_ backend: GraphicsBackend, engine: Engine) -> Bool {
        modules[backend] != nil && engine.info.backends.contains(backend.rawValue)
            && FileManager.default.fileExists(atPath: folder(for: backend, in: engine).path)
    }

    /// Makes the bottle's system folders right for launching `backend` on `engine`: its DLLs in place when the
    /// engine provides them, and anything an earlier launch put there that isn't wanted now replaced by the engine's
    /// own builtin copy. Files someone else changed since (e.g. `WineD3DFallback`) are left alone.
    public static func prepare(_ backend: GraphicsBackend, engine: Engine, bottle: Bottle) throws {
        let fm = FileManager.default
        let wanted = provides(backend, engine: engine) ? modules[backend] ?? [] : []
        let source = folder(for: backend, in: engine)
        for (arch, systemFolder) in architectures {
            let to = bottle.driveC.appendingPathComponent("windows/\(systemFolder)", isDirectory: true)
            guard fm.fileExists(atPath: to.path) else { continue }
            let recordFile = to.appendingPathComponent(record)
            var placed = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: recordFile))) ?? [:]
            let from = source.appendingPathComponent(arch, isDirectory: true)
            var install: [String: Data] = [:]
            if fm.fileExists(atPath: from.path) {
                for module in wanted {
                    if let data = fm.contents(atPath: from.appendingPathComponent("\(module).dll").path) {
                        install[module] = nativeCopy(of: data)
                    }
                }
            }

            for (module, hash) in placed where install[module] == nil {
                let target = to.appendingPathComponent("\(module).dll")
                defer { placed[module] = nil }
                guard let current = fm.contents(atPath: target.path), sha256(current) == hash else { continue }
                let builtin = engine.wineRoot.appendingPathComponent("lib/wine/\(arch)/\(module).dll")
                if let data = fm.contents(atPath: builtin.path) { try data.write(to: target, options: .atomic) }
            }
            for (module, data) in install {
                let target = to.appendingPathComponent("\(module).dll")
                if fm.contents(atPath: target.path) != data { try data.write(to: target, options: .atomic) }
                placed[module] = sha256(data)
            }
            if placed.isEmpty { try? fm.removeItem(at: recordFile) }
            else { try JSONEncoder().encode(placed).write(to: recordFile, options: .atomic) }

            guard !install.isEmpty else { continue }
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

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
