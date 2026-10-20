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

    /// Newest entry (numeric version order).
    public var latest: Entry? { newest(engines) }

    /// Newest entry that provides `backend` (e.g. the D3DMetal engine for DirectX 12 games).
    public func latest(supporting backend: GraphicsBackend) -> Entry? {
        newest(engines.filter { $0.backends?.contains(backend.rawValue) == true })
    }

    private func newest(_ entries: [Entry]) -> Entry? {
        entries.max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    public static func decode(_ data: Data) throws -> EngineManifest {
        try JSONDecoder().decode(EngineManifest.self, from: data)
    }
}
