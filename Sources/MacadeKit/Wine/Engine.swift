import Foundation

public struct EngineInfo: Codable, Sendable, Equatable {
    public var version: String
    public var wineVersion: String
    public var backends: [String]
    public var minMacOS: String

    /// The Wine version for display. Engine 2.0.1 says "11.0 (CrossOver 26.3.0)", which reads as if MaPC ships
    /// CrossOver; it is Wine built from CodeWeavers' published source, so say that instead.
    public var wineDescription: String {
        guard let open = wineVersion.range(of: " (CrossOver "), wineVersion.hasSuffix(")") else { return wineVersion }
        let cx = wineVersion[open.upperBound..<wineVersion.index(before: wineVersion.endIndex)]
        return "\(wineVersion[..<open.lowerBound]), from CrossOver \(cx) source"
    }
}

/// An installed engine: a directory holding `ENGINE.json` and a Wine tree.
public struct Engine: Sendable, Equatable {
    public let directory: URL
    public let info: EngineInfo

    public var version: String { info.version }
    public var wineRoot: URL { Self.findWineRoot(in: directory) ?? directory.appendingPathComponent("wine") }
    public var wine: URL { wineRoot.appendingPathComponent("bin/wine") }
    public var wineserver: URL { wineRoot.appendingPathComponent("bin/wineserver") }
    /// The engine ships Wine Mono in `share/wine/mono` (engine 1.x), which Wine uses for every bottle without
    /// installing it into one. Mafia II: Definitive Edition's .NET launcher needs it.
    public var shipsMono: Bool {
        let mono = wineRoot.appendingPathComponent("share/wine/mono")
        return ((try? FileManager.default.contentsOfDirectory(atPath: mono.path)) ?? []).contains { $0.hasPrefix("wine-mono-") }
    }
    /// The `steamwebhelper` replacement that forces software rendering (spike finding).
    public var steamWebHelperWrapper: URL { directory.appendingPathComponent("steamwebhelper-wrapper.exe") }
    /// Apple's D3DMetal bridge. CrossOver-based engines load it from the path in
    /// `CX_APPLEGPTK_LIBD3DSHARED_PATH`; without it, D3DMetal's DLLs can't call into Metal.
    public var d3dMetalLibrary: URL? {
        let lib = wineRoot.appendingPathComponent("lib/external/libd3dshared.dylib")
        return FileManager.default.fileExists(atPath: lib.path) ? lib : nil
    }

    public init?(directory: URL) {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("ENGINE.json")),
              let info = try? JSONDecoder().decode(EngineInfo.self, from: data) else { return nil }
        self.directory = directory
        self.info = info
    }

    /// Finds `<dir>/wine` or `<dir>/*.app/Contents/Resources/wine` (Gcenx bundles).
    static func findWineRoot(in dir: URL) -> URL? {
        let fm = FileManager.default
        let direct = dir.appendingPathComponent("wine")
        if fm.fileExists(atPath: direct.appendingPathComponent("bin/wine").path) { return direct }
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where item.pathExtension == "app" {
            let root = item.appendingPathComponent("Contents/Resources/wine")
            if fm.fileExists(atPath: root.appendingPathComponent("bin/wine").path) { return root }
        }
        return nil
    }

    public func supports(_ backend: GraphicsBackend) -> Bool {
        if backend == .d3dMetal && d3dMetalLibrary == nil { return false }
        return backend == .auto || backend == .wined3d || info.backends.contains(backend.rawValue)
    }

    public var isUsable: Bool { FileManager.default.isExecutableFile(atPath: wine.path) }

    /// Files, relative to the Wine root, without which no Windows program starts. A report showed engine 1.0.1
    /// without `ntdll.so` (something outside MaPC had removed it): `wine` was still there, so the engine looked
    /// installed and every launch failed with "could not load ntdll.so".
    public static let coreFiles = ["bin/wine", "bin/wineserver", "lib/wine/x86_64-unix/ntdll.so"]

    /// Core files missing from this engine (see `coreFiles`); empty when it's whole.
    public var missingCoreFiles: [String] {
        let root = wineRoot
        return Self.coreFiles.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    /// Files the engine needs are gone, so it has to be reinstalled.
    public var isDamaged: Bool { !missingCoreFiles.isEmpty }
}

public struct EngineLocator: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public func installed() -> [Engine] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.engines, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap(Engine.init(directory:)).filter(\.isUsable)
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// The engine to use for `backend`. The user's active engine wins when it provides the backend
    /// (or the backend is automatic); otherwise the newest engine that does; otherwise the newest.
    public func engine(for backend: GraphicsBackend, activeVersion: String? = nil) -> Engine? {
        let all = installed()
        let active = all.first { $0.version == activeVersion }
        if backend == .auto || active?.info.backends.contains(backend.rawValue) == true, let active { return active }
        if backend != .auto, let match = all.first(where: { $0.info.backends.contains(backend.rawValue) && $0.supports(backend) }) {
            return match
        }
        return active ?? all.first
    }
}
