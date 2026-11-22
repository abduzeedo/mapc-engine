import Foundation

public enum EnvironmentMoveError: Error, LocalizedError, Equatable {
    case notLocal
    case readOnly
    /// exFAT, FAT and NTFS drives: Wine environments need Mac file features they lack (symbolic links, permissions).
    case unsupportedFormat(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case alreadyThere(String)
    case nested
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLocal: "Pick a folder on this Mac or on a drive connected to it. Environments can't run from a network drive."
        case .readOnly: "MaPC can't write to that drive."
        case .unsupportedFormat(let format):
            "That drive is formatted as \(format), which Windows environments can't use. Format it as APFS in Disk Utility (this erases it), or pick another drive."
        case .notEnoughSpace(let needed, let available):
            "The environments need \(Self.bytes(needed)), and that drive has \(Self.bytes(available)) free."
        case .alreadyThere(let name):
            "That folder already has a “\(name)” environment. Pick another folder, or move that one away first."
        case .nested: "Pick a folder outside the environments themselves."
        case .copyFailed(let detail): "Couldn't copy the environments: \(detail)"
        }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

/// Moves MaPC's Windows environments (the folders in `Paths.bottles`) to another folder, for instance on an external
/// drive, and back. Nothing may run in them meanwhile. A failed move leaves everything where it was.
public enum EnvironmentMover {
    /// What a move would do, for checks and the confirmation.
    public struct Plan: Sendable, Equatable {
        public let source: URL
        public let destination: URL
        /// The environment folders to move (store names such as "steam").
        public let names: [String]
        public let sameVolume: Bool
    }

    /// Checks the destination (a `MaPC Environments` folder inside a folder that exists) and lists what moves.
    public static func plan(from source: URL, to destination: URL) throws -> Plan {
        let src = canonical(source), dst = canonical(destination)
        if src.path == dst.path { return Plan(source: source, destination: destination, names: [], sameVolume: true) }
        if dst.path.hasPrefix(src.path + "/") || src.path.hasPrefix(dst.path + "/") { throw EnvironmentMoveError.nested }

        let target = existingAncestor(of: destination)
        let values = try target.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeSupportsSymbolicLinksKey,
                                                         .volumeLocalizedFormatDescriptionKey, .volumeIdentifierKey])
        if values.volumeIsLocal == false { throw EnvironmentMoveError.notLocal }
        if values.volumeIsReadOnly == true { throw EnvironmentMoveError.readOnly }
        let format = values.volumeLocalizedFormatDescription ?? ""
        if values.volumeSupportsSymbolicLinks == false || ["exfat", "ms-dos", "fat", "ntfs"].contains(where: { format.lowercased().contains($0) }) {
            throw EnvironmentMoveError.unsupportedFormat(format.isEmpty ? "a Windows format" : format)
        }

        let names = environmentNames(in: source)
        for name in names where FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path) {
            throw EnvironmentMoveError.alreadyThere(StoreKind(rawValue: name)?.displayName ?? name)
        }
        let sourceVolume = (try? source.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let sameVolume = sourceVolume != nil && sourceVolume == (values.volumeIdentifier as? NSObject)
        if !sameVolume, !names.isEmpty {
            let needed = names.reduce(Int64(0)) { $0 + allocatedSize(of: source.appendingPathComponent($1)) }
            let available = availableCapacity(at: target)
            // A little headroom: the drive shouldn't end up full.
            if let available, available < needed + 512 * 1024 * 1024 {
                throw EnvironmentMoveError.notEnoughSpace(needed: needed, available: available)
            }
        }
        return Plan(source: source, destination: destination, names: names, sameVolume: sameVolume)
    }

    /// Copies (or, on the same drive, renames) every environment into the destination. The originals are only
    /// removed by `removeOriginals` once the new location is saved, so a failure or a crash before that loses nothing.
    public static func move(_ plan: Plan, onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: plan.destination, withIntermediateDirectories: true)
        if plan.sameVolume {
            var moved: [String] = []
            do {
                for name in plan.names {
                    onProgress?("Moving the \(displayName(name)) environment…")
                    try fm.moveItem(at: plan.source.appendingPathComponent(name), to: plan.destination.appendingPathComponent(name))
                    moved.append(name)
                }
            } catch {
                for name in moved { try? fm.moveItem(at: plan.destination.appendingPathComponent(name), to: plan.source.appendingPathComponent(name)) }
                throw EnvironmentMoveError.copyFailed(error.localizedDescription)
            }
            return
        }
        // Copy everything under temporary names first, then rename: a half-copied environment never looks real.
        var copies: [(String, URL)] = []
        do {
            for (index, name) in plan.names.enumerated() {
                try Task.checkCancellation()
                onProgress?("Copying the \(displayName(name)) environment (\(index + 1) of \(plan.names.count))…")
                let temp = plan.destination.appendingPathComponent(".\(name).moving")
                try? fm.removeItem(at: temp)
                copies.append((name, temp))
                // ditto keeps symbolic links as links (a Wine environment's Z: drive links to the Mac's whole disk),
                // and permissions and extended attributes too.
                let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                                                    [plan.source.appendingPathComponent(name).path, temp.path])
                guard r.succeeded else { throw EnvironmentMoveError.copyFailed(r.output.split(separator: "\n").last.map(String.init) ?? "ditto failed") }
            }
            for (name, temp) in copies { try fm.moveItem(at: temp, to: plan.destination.appendingPathComponent(name)) }
        } catch {
            for (name, temp) in copies {
                try? fm.removeItem(at: temp)
                // Renamed already: that copy goes too, the original is still in place.
                let final = plan.destination.appendingPathComponent(name)
                if fm.fileExists(atPath: plan.source.appendingPathComponent(name).path) { try? fm.removeItem(at: final) }
            }
            throw (error as? EnvironmentMoveError) ?? EnvironmentMoveError.copyFailed(error.localizedDescription)
        }
    }

    /// After the new location is saved: removes the originals of a copy, and the old folder when it's left empty.
    public static func removeOriginals(_ plan: Plan) {
        let fm = FileManager.default
        if !plan.sameVolume { for name in plan.names { try? fm.removeItem(at: plan.source.appendingPathComponent(name)) } }
        if plan.source.lastPathComponent == Paths.environmentsFolderName, environmentNames(in: plan.source).isEmpty,
           ((try? fm.contentsOfDirectory(atPath: plan.source.path)) ?? []).allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: plan.source)
        }
    }

    /// The environment folders in `bottles`: every visible folder (a store's name).
    static func environmentNames(in bottles: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: bottles, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return v?.isDirectory == true && v?.isSymbolicLink != true
        }.map(\.lastPathComponent).sorted()
    }

    /// The path with its existing part's links resolved (`/var` is `/private/var`), so two paths compare.
    static func canonical(_ url: URL) -> URL {
        let existing = existingAncestor(of: url)
        let rest = url.standardizedFileURL.pathComponents.dropFirst(existing.pathComponents.count)
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    static func existingAncestor(of url: URL) -> URL {
        var u = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        return u
    }

    static func availableCapacity(at url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return v?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Disk space a folder takes, without following symbolic links (Z: links to the whole Mac).
    static func allocatedSize(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { e.skipDescendants(); continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func displayName(_ name: String) -> String { StoreKind(rawValue: name)?.displayName ?? name }
}
