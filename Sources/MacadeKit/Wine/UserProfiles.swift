import Foundation

/// CrossOver-based engines always keep the Windows profile in `C:\users\crossover` (CodeWeavers' "Hack 12735"
/// in shell32 and advapi32), while stock Wine uses the Mac user name. So a game's AppData would split in two
/// depending on the engine that ran it. `unify` makes `crossover` a link to the real profile, merging what an
/// earlier run put there first. Nothing is deleted: older duplicates go to `<bottle>/profile-backups/`.
/// Only call it while nothing runs in the bottle.
public enum UserProfiles {
    public static let crossOverName = "crossover"

    public struct Report: Equatable, Sendable {
        public var moved: [String] = []
        public var keptAside: [String] = []
        public var linked = false
        public var backupFolder: URL?
    }

    @discardableResult
    public static func unify(bottle: URL, userName: String, now: Date = Date()) throws -> Report {
        var report = Report()
        let fm = FileManager.default
        let users = bottle.appendingPathComponent("drive_c/users")
        let real = users.appendingPathComponent(userName)
        let cx = users.appendingPathComponent(crossOverName)
        guard userName != crossOverName, !userName.isEmpty, isDirectory(real) else { return report }

        if isLink(cx) { return report }                  // already a link (ours, or someone's: leave it)
        if exists(cx) {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = format.string(from: now)
            let backup = bottle.appendingPathComponent("profile-backups/\(stamp)", isDirectory: true)
            report.backupFolder = backup
            try merge(from: cx, into: real, relative: "", backup: backup, report: &report)
            try fm.removeItem(at: cx)                    // empty now: everything was moved or kept aside
            if report.keptAside.isEmpty { report.backupFolder = nil }
        }
        try fm.createSymbolicLink(atPath: cx.path, withDestinationPath: userName)   // relative: survives moves
        report.linked = true
        return report
    }

    private static func merge(from src: URL, into dst: URL, relative: String, backup: URL, report: inout Report) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            let rel = relative.isEmpty ? name : "\(relative)/\(name)"
            if !exists(d) {
                try fm.moveItem(at: s, to: d)
                report.moved.append(rel)
            } else if isLink(s) {
                // Wine links Documents, Desktop... to the Mac's folders; the same link on both sides is a duplicate.
                if isLink(d), (try? fm.destinationOfSymbolicLink(atPath: s.path)) == (try? fm.destinationOfSymbolicLink(atPath: d.path)) {
                    try fm.removeItem(at: s)
                } else {
                    try keepAside(s, rel, backup, &report)
                }
            } else if isLink(d) {
                try keepAside(s, rel, backup, &report)   // never write through a link into the Mac's own folders
            } else if isDirectory(s), isDirectory(d) {
                try merge(from: s, into: d, relative: rel, backup: backup, report: &report)
                try fm.removeItem(at: s)
            } else if !isDirectory(s), !isDirectory(d), modified(s) > modified(d) {
                try keepAside(d, rel, backup, &report)   // the newer copy wins its place; the older is kept
                try fm.moveItem(at: s, to: d)
                report.moved.append(rel)
            } else {
                try keepAside(s, rel, backup, &report)
            }
        }
    }

    private static func keepAside(_ url: URL, _ rel: String, _ backup: URL, _ report: inout Report) throws {
        let target = backup.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: target)
        report.keptAside.append(rel)
    }

    // lstat-based checks: links are never followed.
    private static func attributes(_ url: URL) -> [FileAttributeKey: Any]? { try? FileManager.default.attributesOfItem(atPath: url.path) }
    private static func exists(_ url: URL) -> Bool { attributes(url) != nil }
    private static func isLink(_ url: URL) -> Bool { attributes(url)?[.type] as? FileAttributeType == .typeSymbolicLink }
    private static func isDirectory(_ url: URL) -> Bool { attributes(url)?[.type] as? FileAttributeType == .typeDirectory }
    private static func modified(_ url: URL) -> Date { attributes(url)?[.modificationDate] as? Date ?? .distantPast }
}
