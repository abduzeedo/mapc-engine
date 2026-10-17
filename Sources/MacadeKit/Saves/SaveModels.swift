import Foundation

/// A folder in the game's Windows environment that holds save data. The path is relative to a known root,
/// never absolute, so a backup can be restored into any bottle and a damaged backup can't point elsewhere.
public enum SaveRoot: String, Codable, CaseIterable, Sendable {
    case documents, roaming, local, localLow, savedGames, steamUserdata, install

    public var title: String {
        switch self {
        case .documents: "Documents"
        case .roaming: "AppData\\Roaming"
        case .local: "AppData\\Local"
        case .localLow: "AppData\\LocalLow"
        case .savedGames: "Saved Games"
        case .steamUserdata: "Steam Cloud"
        case .install: "Game folder"
        }
    }
}

public struct SaveSource: Codable, Hashable, Sendable, Identifiable {
    public var root: SaveRoot
    /// Relative, "/"-separated.
    public var path: String

    public init(root: SaveRoot, path: String) {
        self.root = root
        self.path = path
    }

    public var id: String { "\(root.rawValue)/\(path)" }
    public var displayPath: String { ([root.title] + path.split(separator: "/").map(String.init)).joined(separator: "\\") }

    /// No empty parts, no "." or "..", no absolute path, no NUL.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// Where a game's save folders are: the base folder for each `SaveRoot` in one bottle.
public struct SaveRoots: Sendable {
    public let profile: URL
    public let steamUserdata: URL?
    public let install: URL?

    /// `userName` is the Mac user: after `UserProfiles.unify` the real profile is that folder and
    /// `crossover` links to it. A bottle that was never unified only has `crossover`.
    public init(bottle: Bottle, installPath: URL?, userName: String = NSUserName()) {
        let users = bottle.driveC.appendingPathComponent("users", isDirectory: true)
        let real = users.appendingPathComponent(userName, isDirectory: true)
        var isDir: ObjCBool = false
        let hasReal = FileManager.default.fileExists(atPath: real.path, isDirectory: &isDir) && isDir.boolValue
        self.profile = hasReal ? real : users.appendingPathComponent(UserProfiles.crossOverName, isDirectory: true)
        self.steamUserdata = bottle.steamDirectory.appendingPathComponent("userdata", isDirectory: true)
        self.install = installPath
    }

    /// For tests and manual use.
    public init(profile: URL, steamUserdata: URL? = nil, install: URL? = nil) {
        self.profile = profile
        self.steamUserdata = steamUserdata
        self.install = install
    }

    public func base(_ root: SaveRoot) -> URL? {
        switch root {
        case .documents: profile.appendingPathComponent("Documents", isDirectory: true)
        case .roaming: profile.appendingPathComponent("AppData/Roaming", isDirectory: true)
        case .local: profile.appendingPathComponent("AppData/Local", isDirectory: true)
        case .localLow: profile.appendingPathComponent("AppData/LocalLow", isDirectory: true)
        case .savedGames: profile.appendingPathComponent("Saved Games", isDirectory: true)
        case .steamUserdata: steamUserdata
        case .install: install
        }
    }

    /// The base folder with links resolved. Wine links Documents to the Mac's own Documents folder, and
    /// that is where those saves really are.
    func resolvedBase(_ root: SaveRoot) -> URL? { base(root)?.resolvingSymlinksInPath().standardizedFileURL }

    /// The folder a source points to, or nil if the path is unsafe or passes through a link below the base.
    /// The folder may not exist yet (restoring into a fresh environment).
    public func resolve(_ source: SaveSource) -> URL? {
        guard SaveSource.isSafe(source.path), let base = resolvedBase(source.root) else { return nil }
        var url = base
        for part in source.path.split(separator: "/") {
            url.appendPathComponent(String(part), isDirectory: true)
            if FileScan.isSymlink(url) { return nil }
        }
        let standard = url.standardizedFileURL
        return standard.path.hasPrefix(base.path + "/") ? standard : nil
    }

    /// The source for a folder the user picked, using the deepest root that contains it.
    public func source(for url: URL) -> SaveSource? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var best: (root: SaveRoot, base: String)?
        for root in SaveRoot.allCases {
            guard let base = resolvedBase(root)?.path, path.hasPrefix(base + "/") else { continue }
            if best == nil || base.count > best!.base.count { best = (root, base) }
        }
        guard let best else { return nil }
        let relative = String(path.dropFirst(best.base.count + 1))
        return SaveSource.isSafe(relative) ? SaveSource(root: best.root, path: relative) : nil
    }
}

/// Counting and measuring folders without following links.
enum FileScan {
    struct Measure: Equatable {
        var bytes: Int64 = 0
        var files = 0
        var newest: Date?
        var truncated = false
    }

    static func attributes(_ url: URL) -> [FileAttributeKey: Any]? { try? FileManager.default.attributesOfItem(atPath: url.path) }
    static func isSymlink(_ url: URL) -> Bool { attributes(url)?[.type] as? FileAttributeType == .typeSymbolicLink }
    static func isDirectory(_ url: URL) -> Bool { attributes(url)?[.type] as? FileAttributeType == .typeDirectory }
    static func isRegularFile(_ url: URL) -> Bool { attributes(url)?[.type] as? FileAttributeType == .typeRegular }

    /// Size, file count and newest modification date, looking at no more than `limit` entries.
    static func measure(_ root: URL, limit: Int = 20_000) -> Measure {
        var result = Measure()
        var seen = 0
        func walk(_ dir: URL) {
            guard !result.truncated, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names {
                seen += 1
                if seen > limit { result.truncated = true; return }
                let url = dir.appendingPathComponent(name)
                guard let attrs = attributes(url), let type = attrs[.type] as? FileAttributeType else { continue }
                if type == .typeDirectory {
                    walk(url)
                } else if type == .typeRegular {
                    result.files += 1
                    result.bytes += (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    if let date = attrs[.modificationDate] as? Date, date > (result.newest ?? .distantPast) { result.newest = date }
                }
            }
        }
        walk(root)
        return result
    }
}
