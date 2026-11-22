import Foundation
import Testing
@testable import MacadeKit

@Suite struct EpicLauncherStandInTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mapc-standin-\(UUID().uuidString)")
    var gameDir: URL { root.appendingPathComponent("RedDeadRedemption2") }
    var source: URL { root.appendingPathComponent("epic-launcher-standin.exe") }
    let standIn = Data("MZ stand-in ".utf8) + EpicLauncherStandIn.marker + Data("1".utf8)

    init() throws {
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try standIn.write(to: source)
    }

    func bottle() throws -> Bottle {
        let paths = Paths(home: root.appendingPathComponent("MaPC"), environmentsFolder: nil)
        let b = Bottle(kind: .epic, paths: paths)
        try FileManager.default.createDirectory(at: b.driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)
        return b
    }

    func game(store: StoreKind = .epic) -> Game {
        Game(store: store, storeID: "Heather", title: "Red Dead Redemption 2", isInstalled: true, installPath: gameDir)
    }

    @Test func rockstarEpicGameStartsThroughTheStandIn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("MZ".utf8).write(to: gameDir.appendingPathComponent("PlayRDR2.exe"))
        let b = try bottle()
        let env = EpicLauncherStandIn.environment(for: game(), bottle: b, source: source)
        #expect(env == ["LEGENDARY_WRAPPER_EXE": #"C:\windows\command\EpicGamesLauncher.exe"#])
        #expect(FileManager.default.contents(atPath: b.driveC.appendingPathComponent("windows/command/EpicGamesLauncher.exe").path) == standIn)
    }

    @Test func otherGamesAreLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("MZ".utf8).write(to: gameDir.appendingPathComponent("RDR2.exe"))
        let b = try bottle()
        #expect(EpicLauncherStandIn.environment(for: game(), bottle: b, source: source).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: b.driveC.appendingPathComponent("windows/command").path))
    }

    @Test func noStandInWithoutTheAppsCopy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("MZ".utf8).write(to: gameDir.appendingPathComponent("PlayGTAV.exe"))
        let b = try bottle()
        #expect(EpicLauncherStandIn.environment(for: game(), bottle: b, source: nil).isEmpty)
        try Data("MZ unrelated".utf8).write(to: source)
        #expect(EpicLauncherStandIn.environment(for: game(), bottle: b, source: source).isEmpty)
    }

    @Test func neverReplacesSomeoneElsesFileButUpdatesOurOwn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("MZ".utf8).write(to: gameDir.appendingPathComponent("PlayRDR2.exe"))
        let b = try bottle()
        let target = b.driveC.appendingPathComponent("windows/command/EpicGamesLauncher.exe")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = Data("MZ the real Epic launcher".utf8)
        try theirs.write(to: target)
        #expect(EpicLauncherStandIn.environment(for: game(), bottle: b, source: source).isEmpty)
        #expect(FileManager.default.contents(atPath: target.path) == theirs)

        try (Data("MZ old ".utf8) + EpicLauncherStandIn.marker + Data("0".utf8)).write(to: target)
        #expect(!EpicLauncherStandIn.environment(for: game(), bottle: b, source: source).isEmpty)
        #expect(FileManager.default.contents(atPath: target.path) == standIn)
    }
}
