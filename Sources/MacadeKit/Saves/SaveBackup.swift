import Foundation

public enum SaveBackupError: LocalizedError, Equatable {
    case noSources
    case nothingToBackUp
    case destinationUnavailable
    case unsafeBackup
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSources: "Choose which folders hold this game's saves first."
        case .nothingToBackUp: "None of the save folders exist yet. Play the game and save, then try again."
        case .destinationUnavailable: "The backup folder isn't available. Choose a folder in Settings > Pro."
        case .unsafeBackup: "This backup isn't valid, so it wasn't restored."
        case .copyFailed(let detail): "Couldn't copy the saves: \(detail)"
        }
    }
}

/// What a backup contains, stored next to its files.
struct SaveManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var root: SaveRoot
        var path: String
        /// Folder name inside `data/` ("0", "1", ...).
        var folder: String
        var files: Int
        var bytes: Int64
    }

    var format = 1
    var gameID: String
    var gameTitle: String
    var created: Date
    var kind: SaveBackupInfo.Kind
    var entries: [Entry]
}

public struct SaveBackupInfo: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case manual, automatic
        /// A safety copy of the current saves, made just before a restore overwrote them.
        case beforeRestore
    }

    public var folder: URL
    public var gameID: String
    public var gameTitle: String
    public var created: Date
    public var kind: Kind
    public var sources: [SaveSource]
    public var files: Int
    public var bytes: Int64

    public var id: String { folder.lastPathComponent }
}

/// Copies a game's save folders to a backup folder (iCloud Drive or any folder the user picks) and back.
///
/// Layout: `<destination>/MaPC Saves/<title> (<store>-<id>)/<timestamp>/{manifest.json, data/<n>/...}`.
/// Backups are plain copies you can open in Finder. Links inside save folders are skipped, never followed.
/// Restoring overwrites files with the same name, deletes nothing, and first makes a safety backup.
public struct SaveBackupStore: Sendable {
    public static let folderName = "MaPC Saves"

    public let destination: URL
    public var maximumBackups = 20

    public init(destination: URL) { self.destination = destination }

    /// iCloud Drive, when this Mac has it turned on.
    public static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileScan.isDirectory(url) ? url : nil
    }

    var root: URL { destination.appendingPathComponent(Self.folderName, isDirectory: true) }

    // MARK: Create

    @discardableResult
    public func create(gameID: String, title: String, sources: [SaveSource], roots: SaveRoots,
                       kind: SaveBackupInfo.Kind = .manual, now: Date = Date()) throws -> SaveBackupInfo {
        try createSnapshot(gameID: gameID, title: title, sources: sources, roots: roots, kind: kind, now: now, pruning: true)
    }

    private func createSnapshot(gameID: String, title: String, sources: [SaveSource], roots: SaveRoots,
                                kind: SaveBackupInfo.Kind, now: Date, pruning: Bool) throws -> SaveBackupInfo {
        guard !sources.isEmpty else { throw SaveBackupError.noSources }
        guard FileScan.isDirectory(destination) else { throw SaveBackupError.destinationUnavailable }
        let present = sources.compactMap { source -> (SaveSource, URL)? in
            guard let url = roots.resolve(source), FileScan.isDirectory(url) else { return nil }
            return (source, url)
        }
        guard !present.isEmpty else { throw SaveBackupError.nothingToBackUp }

        let fm = FileManager.default
        let gameFolder = try folder(for: gameID, title: title, create: true)
        let name = uniqueName(in: gameFolder, now: now)
        let partial = gameFolder.appendingPathComponent(".partial-\(name)", isDirectory: true)
        let final = gameFolder.appendingPathComponent(name, isDirectory: true)
        do {
            try? fm.removeItem(at: partial)
            try fm.createDirectory(at: partial.appendingPathComponent("data", isDirectory: true), withIntermediateDirectories: true)
            var entries: [SaveManifest.Entry] = []
            for (index, item) in present.enumerated() {
                let target = partial.appendingPathComponent("data/\(index)", isDirectory: true)
                let copied = try Self.copyTree(from: item.1, to: target)
                entries.append(.init(root: item.0.root, path: item.0.path, folder: String(index), files: copied.files, bytes: copied.bytes))
            }
            let manifest = SaveManifest(gameID: gameID, gameTitle: title, created: now, kind: kind, entries: entries)
            try Self.encoder.encode(manifest).write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
            try fm.moveItem(at: partial, to: final)
            if pruning { prune(gameFolder: gameFolder) }
            return Self.info(manifest, folder: final)
        } catch let error as SaveBackupError {
            try? fm.removeItem(at: partial)
            throw error
        } catch {
            try? fm.removeItem(at: partial)
            throw SaveBackupError.copyFailed(error.localizedDescription)
        }
    }

    // MARK: List

    /// This game's backups, newest first.
    public func list(gameID: String, title: String) -> [SaveBackupInfo] {
        guard let gameFolder = try? folder(for: gameID, title: title, create: false),
              let names = try? FileManager.default.contentsOfDirectory(atPath: gameFolder.path) else { return [] }
        return names.compactMap { name -> SaveBackupInfo? in
            guard !name.hasPrefix(".") else { return nil }
            return Self.read(gameFolder.appendingPathComponent(name, isDirectory: true))
        }
        .sorted { $0.created > $1.created }
    }

    // MARK: Restore

    public struct RestoreReport: Equatable, Sendable {
        public var files: Int
        /// The copy of what was there before, if there was anything.
        public var safetyBackup: SaveBackupInfo?
    }

    @discardableResult
    public func restore(_ backup: SaveBackupInfo, roots: SaveRoots, now: Date = Date()) throws -> RestoreReport {
        guard let manifest = Self.readManifest(backup.folder), manifest.format == 1 else { throw SaveBackupError.unsafeBackup }
        // Check everything before touching anything.
        var plan: [(from: URL, to: URL)] = []
        for entry in manifest.entries {
            guard Int(entry.folder) != nil,
                  let target = roots.resolve(SaveSource(root: entry.root, path: entry.path)) else { throw SaveBackupError.unsafeBackup }
            let data = backup.folder.appendingPathComponent("data/\(entry.folder)", isDirectory: true)
            guard FileScan.isDirectory(data), !FileScan.isSymlink(data) else { throw SaveBackupError.unsafeBackup }
            plan.append((data, target))
        }
        let sources = manifest.entries.map { SaveSource(root: $0.root, path: $0.path) }
        let hasCurrentSaves = sources.contains { source in
            roots.resolve(source).map(FileScan.isDirectory) ?? false
        }
        // A disconnected or full backup disk must never turn a restore into an irreversible overwrite.
        // Delay retention until copying finishes so restoring the oldest retained backup cannot prune itself.
        let safety = hasCurrentSaves
            ? try createSnapshot(gameID: manifest.gameID, title: manifest.gameTitle, sources: sources, roots: roots,
                                 kind: .beforeRestore, now: now, pruning: false)
            : nil
        var files = 0
        do {
            for item in plan { files += try Self.copyTree(from: item.from, to: item.to, overwrite: true).files }
        } catch let error as SaveBackupError {
            throw error
        } catch {
            throw SaveBackupError.copyFailed(error.localizedDescription)
        }
        if let gameFolder = try? folder(for: manifest.gameID, title: manifest.gameTitle, create: false) {
            prune(gameFolder: gameFolder)
        }
        return RestoreReport(files: files, safetyBackup: safety)
    }

    // MARK: Changes

    /// True when any file in the sources changed after `date` (to skip a backup when nothing is new).
    public static func hasChanges(sources: [SaveSource], roots: SaveRoots, since date: Date) -> Bool {
        sources.contains { source in
            guard let url = roots.resolve(source), FileScan.isDirectory(url) else { return false }
            return (FileScan.measure(url).newest ?? .distantPast) > date
        }
    }

    // MARK: Folders

    func folder(for gameID: String, title: String, create: Bool) throws -> URL {
        let key = Self.safeID(gameID)
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: root.path),
           let existing = names.first(where: { $0.hasSuffix("(\(key))") }) {
            return root.appendingPathComponent(existing, isDirectory: true)
        }
        let url = root.appendingPathComponent("\(Self.safeTitle(title)) (\(key))", isDirectory: true)
        if create { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    static func safeID(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
    }

    static func safeTitle(_ title: String) -> String {
        let cleaned = title.unicodeScalars.map { scalar -> Character in
            "/\\:*?\"<>|".unicodeScalars.contains(scalar) || scalar.value < 32 ? "-" : Character(scalar)
        }
        let text = String(cleaned).trimmingCharacters(in: .whitespaces)
        return String((text.isEmpty ? "Game" : text).prefix(60))
    }

    private func uniqueName(in folder: URL, now: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        let base = format.string(from: now)
        var name = base, n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    private func prune(gameFolder: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: gameFolder.path) else { return }
        let backups = names.compactMap { name -> SaveBackupInfo? in
            name.hasPrefix(".") ? nil : Self.read(gameFolder.appendingPathComponent(name, isDirectory: true))
        }
        .sorted { $0.created > $1.created }
        for old in backups.dropFirst(maximumBackups) { try? FileManager.default.removeItem(at: old.folder) }
    }

    // MARK: Manifest I/O

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func readManifest(_ folder: URL) -> SaveManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SaveManifest.self, from: data)
    }

    static func read(_ folder: URL) -> SaveBackupInfo? {
        readManifest(folder).map { info($0, folder: folder) }
    }

    static func info(_ manifest: SaveManifest, folder: URL) -> SaveBackupInfo {
        SaveBackupInfo(folder: folder, gameID: manifest.gameID, gameTitle: manifest.gameTitle, created: manifest.created,
                       kind: manifest.kind, sources: manifest.entries.map { SaveSource(root: $0.root, path: $0.path) },
                       files: manifest.entries.reduce(0) { $0 + $1.files }, bytes: manifest.entries.reduce(0) { $0 + $1.bytes })
    }

    // MARK: Copy

    /// Copies a folder's files, keeping modification dates. Links and `.DS_Store` are skipped. With `overwrite`
    /// a file that already exists is replaced; without it the target must not exist yet.
    @discardableResult
    static func copyTree(from source: URL, to target: URL, overwrite: Bool = false) throws -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var files = 0
        var bytes: Int64 = 0
        for name in try fm.contentsOfDirectory(atPath: source.path) where name != ".DS_Store" {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            guard let attrs = FileScan.attributes(from), let type = attrs[.type] as? FileAttributeType else { continue }
            if type == .typeDirectory {
                if FileScan.isSymlink(to) { throw SaveBackupError.unsafeBackup }
                let inner = try copyTree(from: from, to: to, overwrite: overwrite)
                files += inner.files
                bytes += inner.bytes
            } else if type == .typeRegular {
                if FileScan.isSymlink(to) { throw SaveBackupError.unsafeBackup }
                if fm.fileExists(atPath: to.path) {
                    guard overwrite else { throw SaveBackupError.copyFailed(name) }
                    try fm.removeItem(at: to)
                }
                try fm.copyItem(at: from, to: to)
                if let date = attrs[.modificationDate] as? Date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: to.path) }
                files += 1
                bytes += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return (files, bytes)
    }
}
