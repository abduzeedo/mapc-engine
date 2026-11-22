import Foundation

/// Gives each drive connected to the Mac (anything under `/Volumes`) its own Windows drive letter, `D:` onwards.
///
/// Without one, an external drive is only reachable as `Z:\Volumes\<drive>\…`, and Windows programs that ask how
/// much room a drive has ask about the drive's root: Ubisoft Connect and the EA app call `GetDiskFreeSpaceEx` on
/// `Z:\`, which is the Mac's own `/`. So they saw the Mac's free space (125 GB) instead of the external drive's
/// (1.2 TB) and refused to install Assassin's Creed Valhalla (150 GB) there (report 2026-11-22, environments on a
/// 2 TB USB SSD). Wine only gives letters to removable media by itself, and a USB SSD isn't removable to macOS.
///
/// Letters are only ever added, never moved or removed, so a library a launcher saved as `D:\…` stays `D:` and
/// works again as soon as the drive is plugged back in. A letter that already points at a drive (Wine's own, or one
/// the user made in `winecfg`) is kept as it is.
public enum ExternalDrives {
    /// Letters MaPC may hand out. `C:` is the environment's own disk and `Z:` the Mac's `/`.
    static let letters = "defghijklmnopqrstuvwxy".map { "\($0):" }

    /// The drives connected right now: local, writable volumes under `/Volumes` (not the Mac's own disk, disk images
    /// opened read-only, or network shares).
    public static func connectedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix("/Volumes/"), let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsLocal == true && values.volumeIsReadOnly != true && values.volumeIsRootFileSystem != true
        }
    }

    /// Adds a drive letter in `bottle` for each of `volumes` that doesn't have one yet. Returns the letters added,
    /// as `["d:": "/Volumes/SSD"]`. Safe to call before every launch: it does nothing once every drive has a letter.
    @discardableResult
    public static func link(_ volumes: [URL] = connectedVolumes(), in bottle: URL) -> [String: String] {
        let fm = FileManager.default
        let dosdevices = bottle.appendingPathComponent("dosdevices", isDirectory: true)
        guard !volumes.isEmpty, fm.fileExists(atPath: dosdevices.path) else { return [:] }
        let entries = Set(((try? fm.contentsOfDirectory(atPath: dosdevices.path)) ?? []).map { $0.lowercased() })
        // Where each existing letter points, dangling links included (a drive that's unplugged keeps its letter).
        var mapped = Set<String>()
        for entry in entries where entry.count == 2 && entry.hasSuffix(":") {
            let link = dosdevices.appendingPathComponent(entry)
            guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            mapped.insert(URL(fileURLWithPath: target, relativeTo: dosdevices).standardizedFileURL.path)
        }
        var free = letters.filter { !entries.contains($0) }
        var added: [String: String] = [:]
        for volume in volumes {
            let path = volume.standardizedFileURL.path
            guard !mapped.contains(path), !free.isEmpty else { continue }
            let letter = free.removeFirst()
            guard (try? fm.createSymbolicLink(atPath: dosdevices.appendingPathComponent(letter).path,
                                              withDestinationPath: path)) != nil else { continue }
            mapped.insert(path)
            added[letter] = path
        }
        return added
    }
}
