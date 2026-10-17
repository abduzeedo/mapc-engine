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
