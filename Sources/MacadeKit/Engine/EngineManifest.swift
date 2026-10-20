import Foundation

/// Remote description of downloadable engines (`engine-manifest.json`).
public struct EngineManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var version: String
        public var url: URL
        public var sha256: String
        public var size: Int64
        public var minAppVersion: String?
        public var backends: [String]?
        /// Oldest macOS the engine runs on (e.g. "14.0"); no value means any macOS this app runs on.
        public var minMacOS: String?

        /// True when an app at `appVersion` on macOS `macOS` (e.g. "26.7.1") can use this engine.
        public func fits(appVersion: String, macOS: String) -> Bool {
            func atLeast(_ have: String, _ need: String?) -> Bool {
                need.map { have.compare($0, options: .numeric) != .orderedAscending } ?? true
            }
            return atLeast(appVersion, minAppVersion) && atLeast(macOS, minMacOS)
        }
    }

    /// An installed engine the list no longer offers, and the listed engine that takes over from it.
    public struct Update: Equatable, Sendable {
        public var installed: String
        public var replacement: Entry
        public init(installed: String, replacement: Entry) {
            self.installed = installed
            self.replacement = replacement
        }
    }

    public var engines: [Entry]
    /// Steam command line, fixable without an app release.
    public var steamArgs: [String]?
    public var knownIssues: [String: String]?

    /// Only the entries an app at `appVersion` can use: no minimum, or one it meets. Apps before 1.1.4 ignored
    /// `minAppVersion`, so engines that need a newer app go in a separate list those apps never read.
    public func usable(byApp appVersion: String) -> EngineManifest {
        var usable = self
        usable.engines = engines.filter { entry in
            entry.minAppVersion.map { appVersion.compare($0, options: .numeric) != .orderedAscending } ?? true
        }
        return usable
    }

    /// Installed engines this list has dropped, each with the newest listed engine that replaces it: a newer version
    /// that provides every backend the old one did and fits this app and macOS. Engine 2.0.1, for one, was dropped
    /// because it crashes at start on macOS 26; 2.0.2 replaces it. Engines the list still offers, engines newer than
    /// anything listed (private test builds) and engines nothing listed can replace are left alone.
    /// Call this on the whole list, not on `usable(byApp:)`: an engine listed for newer apps only isn't dropped.
    public func updates(for installed: [EngineInfo], appVersion: String,
                        macOS: String = EngineManifest.macOSVersion) -> [Update] {
        let listed = Set(engines.map(\.version))
        let fitting = engines.filter { $0.fits(appVersion: appVersion, macOS: macOS) }
        return installed.filter { !listed.contains($0.version) }.compactMap { old in
            let candidates = fitting.filter { entry in
                entry.version.compare(old.version, options: .numeric) == .orderedDescending
                    && Set(entry.backends ?? []).isSuperset(of: old.backends)
            }
            return newest(candidates).map { Update(installed: old.version, replacement: $0) }
        }
    }

    /// Newest entry (numeric version order).
    public var latest: Entry? { newest(engines) }

    /// Newest entry that provides `backend` (e.g. the D3DMetal engine for DirectX 12 games).
    public func latest(supporting backend: GraphicsBackend) -> Entry? {
        newest(engines.filter { $0.backends?.contains(backend.rawValue) == true })
    }

    private func newest(_ entries: [Entry]) -> Entry? {
        entries.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    /// This Mac's macOS version, e.g. "26.7.1".
    public static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static func decode(_ data: Data) throws -> EngineManifest {
        try JSONDecoder().decode(EngineManifest.self, from: data)
    }
}

