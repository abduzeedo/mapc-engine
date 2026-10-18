import Foundation
import Testing
@testable import MacadeKit

@Suite struct SaveRestoreSafetyTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mapc-restore-safety-\(UUID().uuidString)")
    var roots: SaveRoots { SaveRoots(profile: root.appendingPathComponent("profile")) }
    var save: URL { roots.profile.appendingPathComponent("AppData/Roaming/Game/slot.sav") }
    let source = SaveSource(root: .roaming, path: "Game")
    init() throws {
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old save".write(to: save, atomically: true, encoding: .utf8)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    @Test func unavailableSafetyDestinationNeverOverwritesProgress() throws {
        defer { cleanup() }
        let backup = try SaveBackupStore(destination: root).create(gameID: "steam:1", title: "Game", sources: [source], roots: roots)
        try "new progress".write(to: save, atomically: true, encoding: .utf8)
        let unavailable = SaveBackupStore(destination: root.appendingPathComponent("disconnected-drive"))
        #expect(throws: SaveBackupError.destinationUnavailable) { try unavailable.restore(backup, roots: roots) }
        #expect(try String(contentsOf: save, encoding: .utf8) == "new progress")
    }

    @Test func freshEnvironmentNeedsNoSafetyCopy() throws {
        defer { cleanup() }
        let backup = try SaveBackupStore(destination: root).create(gameID: "steam:1", title: "Game", sources: [source], roots: roots)
        try FileManager.default.removeItem(at: roots.profile)
        let result = try SaveBackupStore(destination: root).restore(backup, roots: roots)
        #expect(result.safetyBackup == nil)
        #expect(try String(contentsOf: save, encoding: .utf8) == "old save")
    }

    @Test func safetyRetentionCannotDeleteRestoreSourceBeforeCopy() throws {
        defer { cleanup() }
        var store = SaveBackupStore(destination: root)
        store.maximumBackups = 1
        let backup = try store.create(gameID: "steam:1", title: "Game", sources: [source], roots: roots, now: Date(timeIntervalSince1970: 1_800_000_000))
        try "new progress".write(to: save, atomically: true, encoding: .utf8)
        let result = try store.restore(backup, roots: roots, now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(result.safetyBackup != nil)
        #expect(try String(contentsOf: save, encoding: .utf8) == "old save")
        #expect(try String(contentsOf: #require(result.safetyBackup).folder.appendingPathComponent("data/0/slot.sav"), encoding: .utf8) == "new progress")
    }
}
