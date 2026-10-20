import Foundation

/// Wine's own Direct3D for the Rockstar Games Launcher in bottles that run D3DMetal.
///
/// D3DMetal replaces `d3d10`, `d3d11` and `dxgi` but ships no `d3d10_1`/`d3d10core`, so the launcher's
/// Direct3D 10.1 device (it draws its UI with Direct2D on top) lands on Wine's d3d10core talking to Apple's
/// dxgi, fails, and the launcher shows "failed to initialize". Giving the launcher Wine's complete stack fixes it.
///
/// The launcher only searches System32 for these DLLs, so Wine's copies go there as *native* DLLs (builtin
/// marker cleared, which also stops `wineboot` from overwriting them), and only `Launcher.exe` is told to
/// prefer native. Every other program keeps the builtin load order and so keeps D3DMetal. The launcher's
/// Direct3D 12 probe is switched off too: Apple's d3d12 on Wine's dxgi crashes it, and it only reads GPU info.
public struct WineD3DFallback: Sendable {
    static let modules = ["d3d10", "d3d11", "dxgi"]
    static let apps = ["Launcher.exe"]
    /// Turned off for those apps (the launcher only probes them).
    static let disabled = ["d3d12", "d3d12core"]
    /// Lists what we installed, so we only ever remove our own files.
    static let marker = ".macade-wine-d3d"
    /// Bump when the overrides change, so bottles set up earlier get them again.
    static let revision = 2

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// Where an engine keeps Wine's DLLs that D3DMetal replaced (outside Wine's DLL search path).
    static func stash(in engine: Engine) -> URL {
        engine.wineRoot.appendingPathComponent("lib/wine-d3d/x86_64-windows", isDirectory: true)
    }

    /// Saves Wine's `d3d10`/`d3d11`/`dxgi` before D3DMetal overwrites them. Skips anything already
    /// stashed or that isn't Wine's build.
    static func stashOriginals(of engine: Engine) throws {
        let fm = FileManager.default
        let windows = engine.wineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let stash = stash(in: engine)
        for module in modules {
            let source = windows.appendingPathComponent("\(module).dll")
            let saved = stash.appendingPathComponent("\(module).dll")
            guard !fm.fileExists(atPath: saved.path), let data = fm.contents(atPath: source.path),
                  isWineBuild(data) else { continue }
            try fm.createDirectory(at: stash, withIntermediateDirectories: true)
            try data.write(to: saved)
        }
    }

    /// Wine-built PE with the builtin marker, and not one of D3DMetal's (which carry the same marker).
    static func isWineBuild(_ dll: Data) -> Bool {
        dll.count > 0x50 && dll[0x40..<0x50].elementsEqual("Wine builtin DLL".utf8)
            && dll.range(of: Data("D3DMetalDLLs".utf8)) == nil
    }

    /// The same DLL marked native: Wine then loads it as an ordinary Windows DLL.
    static func nativeCopy(of dll: Data) -> Data {
        var copy = dll
        copy.replaceSubrange(0x40..<0x50, with: Data(count: 16))
        return copy
    }

    /// Installs the fallback when `engine` runs D3DMetal and has Wine's originals; otherwise removes it and puts
    /// `engine`'s own DLLs back (a DXVK engine needs System32 free for its own DLLs). Call before starting anything in the bottle.
    public func update(_ kind: BottleKind, engine: Engine) async {
        let bottle = Bottle(kind: kind, paths: paths)
        guard bottle.exists else { return }
        let fm = FileManager.default
        let system32 = bottle.driveC.appendingPathComponent("windows/system32")
        let markerFile = system32.appendingPathComponent(Self.marker)
        let markerValue = "\(engine.version) r\(Self.revision)"
        let stash = Self.stash(in: engine)
        let wanted = engine.supports(.d3dMetal)
            && Self.modules.allSatisfy { fm.fileExists(atPath: stash.appendingPathComponent("\($0).dll").path) }

        if wanted {
            var changed = false
            for module in Self.modules {
                guard let data = fm.contents(atPath: stash.appendingPathComponent("\(module).dll").path) else { return }
                let native = Self.nativeCopy(of: data)
                let target = system32.appendingPathComponent("\(module).dll")
                if fm.contents(atPath: target.path) == native { continue }
                do { try native.write(to: target, options: .atomic) } catch { return }
                changed = true
            }
            guard changed || (try? String(contentsOf: markerFile, encoding: .utf8)) != markerValue else { return }
            await setOverrides(true, engine: engine, bottle: bottle)
            try? markerValue.write(to: markerFile, atomically: true, encoding: .utf8)
        } else {
            let installed = fm.fileExists(atPath: markerFile.path)
            Self.restoreBuiltins(in: system32, engine: engine, replacingFallback: installed)
            guard installed else { return }
            await setOverrides(false, engine: engine, bottle: bottle)
            try? fm.removeItem(at: markerFile)
        }
    }

    /// Puts `engine`'s own builtin copies where the fallback's native copies are (when `replacingFallback`) and
    /// where they are missing. Waiting for Wine's prefix update isn't enough: by the time this runs, the new engine
    /// has usually updated the prefix already, so nothing puts them back, and Steam's helper then fails to load
    /// `dxgi.dll`. Earlier versions removed them that way, hence missing files are restored on every call.
    /// Files someone else changed, and copies `NativeBackendDLLs` put there, are left alone.
    static func restoreBuiltins(in system32: URL, engine: Engine, replacingFallback: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: system32.path) else { return }
        let windows = engine.wineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let nativeBackend = (try? JSONDecoder().decode([String: String].self, from:
            Data(contentsOf: system32.appendingPathComponent(NativeBackendDLLs.record)))) ?? [:]
        for module in modules {
            let target = system32.appendingPathComponent("\(module).dll")
            if let current = fm.contents(atPath: target.path) {
                guard replacingFallback, isFallbackCopy(current),
                      nativeBackend[module] != NativeBackendDLLs.sha256(current) else { continue }
            }
            if let builtin = fm.contents(atPath: windows.appendingPathComponent("\(module).dll").path) {
                try? builtin.write(to: target, options: .atomic)
            } else if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
            }
        }
    }

    /// What `update` installs: a Wine build with its builtin marker cleared.
    static func isFallbackCopy(_ dll: Data) -> Bool {
        guard dll.count > 0x50, dll[dll.startIndex + 0x40..<dll.startIndex + 0x50].allSatisfy({ $0 == 0 }) else { return false }
        var marked = dll
        marked.replaceSubrange(marked.startIndex + 0x40..<marked.startIndex + 0x50, with: Data("Wine builtin DLL".utf8))
        return isWineBuild(Data(marked))
    }

    private func setOverrides(_ on: Bool, engine: Engine, bottle: Bottle) async {
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        for app in Self.apps {
            let key = #"HKCU\Software\Wine\AppDefaults\"# + app + #"\DllOverrides"#
            if on {
                let values = (Self.modules + ["d3d10_1", "d3d10core"]).map { ($0, "native,builtin") } + Self.disabled.map { ($0, "") }
                for (module, order) in values {
                    _ = try? await ProcessRunner.run(engine.wine, ["reg", "add", key, "/v", module, "/d", order, "/f"],
                                                     environment: env)
                }
            } else {
                _ = try? await ProcessRunner.run(engine.wine, ["reg", "delete", key, "/f"], environment: env)
            }
        }
    }
}
