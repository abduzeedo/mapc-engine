import Foundation

/// Per-game rotating log files: `Logs/<gameId>/<timestamp>.log`, keeping the newest `keep`.
public struct LogStore: Sendable {
    public let paths: Paths
    public let keep: Int

    public init(paths: Paths, keep: Int = 5) {
        self.paths = paths
        self.keep = keep
    }

    /// Creates a new log file for a run and prunes old ones.
    public func newLog(for gameID: String, now: Date = Date()) throws -> URL {
        let dir = paths.gameLogs(gameID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.stamp(now) + ".log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try prune(dir)
        return url
    }

    public func logs(for gameID: String) -> [URL] {
        let dir = paths.gameLogs(gameID)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The last `lines` lines of a log, for the "Show Details" error UX.
    public func excerpt(of log: URL, lines: Int = 40) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    private func prune(_ dir: URL) throws {
        let files = (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }
}
