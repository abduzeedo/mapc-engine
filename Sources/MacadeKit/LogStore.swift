import Foundation

/// Per-game rotating log files: `Logs/<gameId>/<timestamp>.log`, keeping the newest `keep`.
///
/// A log is written straight by Wine, so its size can't be capped while it runs. Instead every new log also tidies
/// the whole folder: finished logs over `trimAbove` keep their first `headBytes` and last `tailBytes` (what
/// `LogDiagnosis.read` and reports read), and finished logs older than `maxAge` (a day) go. A user wrote that the
/// logs took too much space; the owner's own folder held 12 GB, with single logs up to 6.4 GB.
public struct LogStore: Sendable {
    public let paths: Paths
    public let keep: Int
    public var maxAge: TimeInterval = 86_400
    public var trimAbove: UInt64 = 8 << 20
    public var headBytes = 64 << 10
    public var tailBytes = 2 << 20
    /// A log without its `[MaPC] Exit` line that changed this recently may still be written to: never touched.
    public var quietFor: TimeInterval = 86_400

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
        tidy(now: now, except: url)
        return url
    }

    /// Trims big finished logs and removes old ones (and folders left empty) in every game's folder.
    public func tidy(now: Date = Date(), except current: URL? = nil) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for dir in (try? fm.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: nil)) ?? [] {
            let logs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
                .filter { $0.pathExtension == "log" && $0.standardizedFileURL != current?.standardizedFileURL }
            for log in logs {
                guard let values = try? log.resourceValues(forKeys: Set(keys)) else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                let finished = now.timeIntervalSince(modified) > quietFor || Self.tail(of: log, bytes: 4096).contains("[MaPC] Exit")
                guard finished else { continue }
                if now.timeIntervalSince(modified) > maxAge { try? fm.removeItem(at: log); continue }
                if UInt64(values.fileSize ?? 0) > trimAbove { trim(log) }
            }
            if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty { try? fm.removeItem(at: dir) }
        }
    }

    /// Keeps the start (the launch line, the game's first errors) and the end (the crash), with a note between.
    func trim(_ log: URL) {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        try? handle.seek(toOffset: size - UInt64(tailBytes))
        let tail = (try? handle.readToEnd()) ?? Data()
        let removed = Int64(size) - Int64(head.count) - Int64(tail.count)
        let note = "\n[MaPC] Trimmed \(ByteCountFormatter.string(fromByteCount: removed, countStyle: .file)) of log here to save space\n"
        let temp = log.deletingLastPathComponent().appendingPathComponent(".\(log.lastPathComponent).trim")
        guard FileManager.default.createFile(atPath: temp.path, contents: head + Data(note.utf8) + tail) else { return }
        _ = try? FileManager.default.replaceItemAt(log, withItemAt: temp)
        try? FileManager.default.removeItem(at: temp)
    }

    static func tail(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    public func logs(for gameID: String) -> [URL] {
        let dir = paths.gameLogs(gameID)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The last `lines` lines of a log, for the "Show Details" error UX.
    public func excerpt(of log: URL, lines: Int = 40) -> String {
        // Only the end: a running game's log can be gigabytes.
        let text = Self.tail(of: log, bytes: max(lines, 1) * 1024)
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
