import Foundation
import Testing
@testable import MacadeKit

@Suite struct UserProfilesTests {
    let fm = FileManager.default

    /// A bottle shaped like the real ones: `users/<name>` with AppData, and Wine's links to the Mac's folders.
    func makeBottle() throws -> (bottle: URL, mac: URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        let mac = root.appendingPathComponent("MacHome")
        for dir in ["Documents", "Desktop"] { try fm.createDirectory(at: mac.appendingPathComponent(dir), withIntermediateDirectories: true) }
        let bottle = root.appendingPathComponent("bottle")
        try fm.createDirectory(at: bottle.appendingPathComponent("drive_c/users/Public"), withIntermediateDirectories: true)
        return (bottle, mac)
    }

    func profile(_ bottle: URL, _ name: String, mac: URL, desktopIsFolder: Bool = false) throws -> URL {
        let p = bottle.appendingPathComponent("drive_c/users/\(name)")
        try fm.createDirectory(at: p.appendingPathComponent("AppData/Local"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: p.appendingPathComponent("Documents"), withDestinationURL: mac.appendingPathComponent("Documents"))
        if desktopIsFolder {
            try fm.createDirectory(at: p.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: p.appendingPathComponent("Desktop/My Mac Desktop"), withDestinationURL: mac.appendingPathComponent("Desktop"))
        } else {
            try fm.createSymbolicLink(at: p.appendingPathComponent("Desktop"), withDestinationURL: mac.appendingPathComponent("Desktop"))
        }
        return p
    }

    func write(_ text: String, _ url: URL, modified: Date) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func mergesCrossOverProfileIntoTheRealOneAndLinksIt() throws {
        let (bottle, mac) = try makeBottle()
        defer { try? fm.removeItem(at: bottle.deletingLastPathComponent()) }
        let real = try profile(bottle, "player", mac: mac)
        let cx = try profile(bottle, "crossover", mac: mac, desktopIsFolder: true)
        let old = Date(timeIntervalSince1970: 1_000_000), new = Date(timeIntervalSince1970: 2_000_000)
        try write("real-only", real.appendingPathComponent("AppData/Local/Cuphead/a.sav"), modified: old)
        try write("cx-only", cx.appendingPathComponent("AppData/Local/Kena/Saved/b.sav"), modified: new)
        try write("older", real.appendingPathComponent("AppData/Local/Sifu/s.sav"), modified: old)
        try write("newer", cx.appendingPathComponent("AppData/Local/Sifu/s.sav"), modified: new)
        try write("newer-real", real.appendingPathComponent("AppData/Local/Steam/local.vdf"), modified: new)
        try write("older-cx", cx.appendingPathComponent("AppData/Local/Steam/local.vdf"), modified: old)

        let r = try UserProfiles.unify(bottle: bottle, userName: "player", now: Date(timeIntervalSince1970: 3_000_000))

        #expect(r.linked)
        #expect(try fm.destinationOfSymbolicLink(atPath: cx.path) == "player")
        #expect(read(real.appendingPathComponent("AppData/Local/Cuphead/a.sav")) == "real-only")
        #expect(read(real.appendingPathComponent("AppData/Local/Kena/Saved/b.sav")) == "cx-only")
        #expect(read(real.appendingPathComponent("AppData/Local/Sifu/s.sav")) == "newer")            // newest wins
        #expect(read(real.appendingPathComponent("AppData/Local/Steam/local.vdf")) == "newer-real")
        let backup = try #require(r.backupFolder)
        #expect(read(backup.appendingPathComponent("AppData/Local/Sifu/s.sav")) == "older")         // nothing lost
        #expect(read(backup.appendingPathComponent("AppData/Local/Steam/local.vdf")) == "older-cx")
        #expect(backup.path.hasPrefix(bottle.path) && !backup.path.contains("drive_c"))             // not visible as C:
        // The crossover profile is now the same folder.
        #expect(read(cx.appendingPathComponent("AppData/Local/Kena/Saved/b.sav")) == "cx-only")
    }

    @Test func neverWritesThroughLinksIntoMacFolders() throws {
        let (bottle, mac) = try makeBottle()
        defer { try? fm.removeItem(at: bottle.deletingLastPathComponent()) }
        let real = try profile(bottle, "player", mac: mac)                     // Desktop -> Mac Desktop
        _ = try profile(bottle, "crossover", mac: mac, desktopIsFolder: true) // Desktop is a folder with a link inside
        let r = try UserProfiles.unify(bottle: bottle, userName: "player")
        #expect(try fm.contentsOfDirectory(atPath: mac.appendingPathComponent("Desktop").path).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: mac.appendingPathComponent("Documents").path).isEmpty)
        #expect(r.keptAside == ["Desktop"])
        #expect(try fm.destinationOfSymbolicLink(atPath: real.appendingPathComponent("Documents").path) == mac.appendingPathComponent("Documents").path)
    }

    @Test func freshBottleJustGetsTheLinkAndRunsAreIdempotent() throws {
        let (bottle, mac) = try makeBottle()
        defer { try? fm.removeItem(at: bottle.deletingLastPathComponent()) }
        _ = try profile(bottle, "player", mac: mac)
        let first = try UserProfiles.unify(bottle: bottle, userName: "player")
        #expect(first.linked && first.moved.isEmpty && first.backupFolder == nil)
        let second = try UserProfiles.unify(bottle: bottle, userName: "player")
        #expect(second == UserProfiles.Report())                              // already linked: no-op
    }

    @Test func leavesBottlesWithoutARealProfileAlone() throws {
        let (bottle, mac) = try makeBottle()
        defer { try? fm.removeItem(at: bottle.deletingLastPathComponent()) }
        let cx = try profile(bottle, "crossover", mac: mac)
        #expect(try UserProfiles.unify(bottle: bottle, userName: "player") == UserProfiles.Report())
        #expect((try? fm.destinationOfSymbolicLink(atPath: cx.path)) == nil)  // still a real folder
        #expect(try UserProfiles.unify(bottle: bottle, userName: "crossover") == UserProfiles.Report())
    }
}
