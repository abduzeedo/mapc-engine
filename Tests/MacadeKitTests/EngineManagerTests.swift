import Foundation
import CryptoKit
import Testing
@testable import MacadeKit

/// Builds tiny fake engines (a shell script posing as `wine`) packed as real .tar.xz archives.
private struct FakeEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("macade-eng-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func archive(version: String, wineExit: Int = 0, withJSON: Bool = true) throws -> URL {
        let dir = root.appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        let wine = dir.appendingPathComponent("wine/bin/wine")
        try "#!/bin/sh\necho wine-fake\nexit \(wineExit)\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        if withJSON {
            try #"{"version":"\#(version)","wineVersion":"fake","backends":["dxvk"],"minMacOS":"15.0"}"#
                .write(to: dir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        }
        let out = root.appendingPathComponent("engine-\(version)-\(UUID().uuidString).tar.xz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cJf", out.path, "-C", dir.path, "."]
        try p.run(); p.waitUntilExit()
        return out
    }

    func entry(for archive: URL, version: String, sha: String? = nil, size: Int64? = nil) throws -> EngineManifest.Entry {
        let data = try Data(contentsOf: archive)
        let digest = sha ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(version: version, url: archive, sha256: digest, size: size ?? Int64(data.count), minAppVersion: nil, backends: ["dxvk"])
    }
}

@Suite struct EngineManagerTests {
    fileprivate func manager() -> (EngineManager, Paths, FakeEngine) {
        let fake = FakeEngine()
        return (EngineManager(paths: Paths(home: fake.root.appendingPathComponent("home"))), Paths(home: fake.root.appendingPathComponent("home")), fake)
    }

    @Test func installsAVerifiedEngine() async throws {
        let (mgr, paths, fake) = manager(); defer { fake.cleanup() }
        let archive = try fake.archive(version: "1.2.0")
        let phases = PhaseLog()
        let engine = try await mgr.install(try fake.entry(for: archive, version: "1.2.0")) { phase, _ in phases.add(phase) }
        #expect(engine.version == "1.2.0")
        #expect(FileManager.default.fileExists(atPath: paths.engine(version: "1.2.0").appendingPathComponent("ENGINE.json").path))
        #expect(EngineLocator(paths: paths).installed().map(\.version) == ["1.2.0"])
        #expect(phases.all.contains(.downloading) && phases.all.contains(.verifying) && phases.all.contains(.extracting))
        // no temp files left behind
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: paths.engines.path)).filter { $0.hasPrefix(".install") }
        #expect(leftovers.isEmpty)
    }

    @Test func corruptedDownloadFailsTheChecksum() async throws {
        let (mgr, paths, fake) = manager(); defer { fake.cleanup() }
        let archive = try fake.archive(version: "1.0.0")
        let bad = try fake.entry(for: archive, version: "1.0.0", sha: String(repeating: "0", count: 64))
        await #expect(throws: EngineError.checksumMismatch) { try await mgr.install(bad) }
        #expect(EngineLocator(paths: paths).installed().isEmpty)
    }

    @Test func wrongSizeIsRejected() async throws {
        let (mgr, _, fake) = manager(); defer { fake.cleanup() }
        let archive = try fake.archive(version: "1.0.0")
        await #expect(throws: EngineError.sizeMismatch) { try await mgr.install(try fake.entry(for: archive, version: "1.0.0", size: 5)) }
    }

    @Test func archiveWithoutEngineJSONIsInvalid() async throws {
        let (mgr, _, fake) = manager(); defer { fake.cleanup() }
        let archive = try fake.archive(version: "1.0.0", withJSON: false)
        await #expect(throws: EngineError.invalidEngine) { try await mgr.install(try fake.entry(for: archive, version: "1.0.0")) }
    }

    @Test func versionMismatchIsInvalid() async throws {
        let (mgr, _, fake) = manager(); defer { fake.cleanup() }
        let archive = try fake.archive(version: "2.0.0")
        await #expect(throws: EngineError.invalidEngine) { try await mgr.install(try fake.entry(for: archive, version: "1.0.0")) }
    }

    @Test func engineThatWontStartIsRolledBack() async throws {
        let (mgr, paths, fake) = manager(); defer { fake.cleanup() }
        // A good 1.0.0 is installed first, then a broken replacement must not destroy it.
        _ = try await mgr.install(try fake.entry(for: try fake.archive(version: "1.0.0"), version: "1.0.0"))
        let broken = try fake.archive(version: "1.0.0", wineExit: 1)
        await #expect(throws: EngineError.sanityCheckFailed) { try await mgr.install(try fake.entry(for: broken, version: "1.0.0")) }
        #expect(EngineLocator(paths: paths).installed().map(\.version) == ["1.0.0"])
    }

    @Test func missingFileFailsCleanly() async throws {
        let (mgr, _, fake) = manager(); defer { fake.cleanup() }
        let entry = EngineManifest.Entry(version: "1.0.0", url: fake.root.appendingPathComponent("nope.tar.xz"), sha256: "00", size: 0, minAppVersion: nil, backends: nil)
        await #expect(throws: EngineError.self) { try await mgr.install(entry) }
    }
}

private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock(); private var items: [EnginePhase] = []
    func add(_ p: EnginePhase) { lock.lock(); if items.last != p { items.append(p) }; lock.unlock() }
    var all: [EnginePhase] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite struct ManifestAndStoreTests {
    @Test func manifestDecodesAndPicksNumericLatest() throws {
        let json = #"""
        {"engines":[{"version":"1.9.0","url":"https://x/a.tar.xz","sha256":"aa","size":1},
                    {"version":"1.10.0","url":"https://x/b.tar.xz","sha256":"bb","size":2,"backends":["dxvk"]}],
         "steamArgs":["-a","-b"],"knownIssues":{"steam:1":"Anti-cheat"}}
        """#
        let m = try EngineManifest.decode(Data(json.utf8))
        #expect(m.latest?.version == "1.10.0")
        #expect(m.steamArgs == ["-a", "-b"])
        #expect(m.knownIssues?["steam:1"] == "Anti-cheat")
        #expect(throws: DecodingError.self) { try EngineManifest.decode(Data("{}".utf8)) }
    }

    @Test func manifestPicksNewestEngineForABackend() throws {
        let json = #"""
        {"engines":[{"version":"1.0.0","url":"https://x/a","sha256":"aa","size":1,"backends":["dxvk"]},
                    {"version":"1.1.0","url":"https://x/b","sha256":"bb","size":1,"backends":["dxvk"]},
                    {"version":"2.0.0","url":"https://x/c","sha256":"cc","size":1,"backends":["d3dMetal"]},
                    {"version":"9.0.0","url":"https://x/d","sha256":"dd","size":1}]}
        """#
        let m = try EngineManifest.decode(Data(json.utf8))
        #expect(m.latest(supporting: .dxvk)?.version == "1.1.0")
        #expect(m.latest(supporting: .d3dMetal)?.version == "2.0.0")
        #expect(m.latest(supporting: .dxmt) == nil)
    }

    @Test func settingsWrittenBeforeBottleEnginesStillLoad() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // The exact shape of a Settings.json from the previous release.
        try #"{"appliedRetina":{"steam":true},"onboardingCompleted":true,"verboseLogs":false}"#
            .write(to: paths.settingsFile, atomically: true, encoding: .utf8)
        let loaded = JSONStore<AppSettings>(url: paths.settingsFile).load(default: AppSettings())
        #expect(loaded.onboardingCompleted)
        #expect(loaded.bottleEngines == nil)
    }

    @Test func settingsAndLibraryRoundTrip() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let store = JSONStore<AppSettings>(url: paths.settingsFile)
        #expect(store.load(default: AppSettings()).onboardingCompleted == false)   // missing file -> default
        var s = AppSettings(); s.onboardingCompleted = true; s.activeEngineVersion = "1.0.0"; s.appliedRetina["steam"] = true
        try store.save(s)
        #expect(store.load(default: AppSettings()) == s)
        try "garbage".write(to: paths.settingsFile, atomically: true, encoding: .utf8)
        #expect(store.load(default: AppSettings()).activeEngineVersion == nil)       // corrupt file -> default, no crash
        #expect(FileManager.default.fileExists(atPath: paths.settingsFile.appendingPathExtension("corrupt").path))  // kept, not lost
    }

    @Test func libraryMergeKeepsOtherStoreAndUserData() {
        let steam = Game(store: .steam, storeID: "1", title: "Beta", isInstalled: true)
        let epicOld = Game(store: .epic, storeID: "a", title: "Old", isInstalled: false)
        let epicNew = Game(store: .epic, storeID: "b", title: "alpha", isInstalled: true)
        let merged = LibraryStore.merged(cached: [steam, epicOld], replacing: .epic, with: [epicNew])
        #expect(merged.map(\.id) == ["epic:b", "steam:1"])
        var data: [String: UserGameData] = ["epic:b": UserGameData(), "epic:gone": UserGameData()]
        data["epic:b"]?.playTime = 42
        let pruned = LibraryStore.pruned(data, keeping: merged)
        #expect(pruned.keys.sorted() == ["epic:b"])
        #expect(pruned["epic:b"]?.playTime == 42)
    }

    @Test func locatorPrefersActiveEngine() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for (v, b) in [("1.0.0", "dxvk"), ("2.0.0", "dxvk")] {
            let dir = home.appendingPathComponent("Engines/\(v)/wine/bin")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let wine = dir.appendingPathComponent("wine"); try "#!/bin/sh".write(to: wine, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
            try #"{"version":"\#(v)","wineVersion":"x","backends":["\#(b)"],"minMacOS":"15"}"#
                .write(to: home.appendingPathComponent("Engines/\(v)/ENGINE.json"), atomically: true, encoding: .utf8)
        }
        let loc = EngineLocator(paths: Paths(home: home))
        #expect(loc.engine(for: .auto)?.version == "2.0.0")
        #expect(loc.engine(for: .auto, activeVersion: "1.0.0")?.version == "1.0.0")   // rollback choice honored
        #expect(loc.engine(for: .dxvk, activeVersion: "1.0.0")?.version == "1.0.0")
        #expect(loc.engine(for: .dxvk, activeVersion: "9.9.9")?.version == "2.0.0")  // stale setting ignored
    }
}

@Suite struct PersistenceRegressionTests {
    @Test func libraryWithDatesSurvivesARoundTrip() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LibraryStore(paths: Paths(home: home))
        var file = LibraryFile()
        file.games = [Game(store: .steam, storeID: "1", title: "A", isInstalled: true)]
        var data = UserGameData()
        data.lastPlayed = Date(timeIntervalSince1970: 1_791_000_000)
        data.playTime = 3600
        data.profile.backend = .dxvk
        data.profile.extraEnvironment = ["A": "1"]
        file.userData["steam:1"] = data
        store.save(file)
        let loaded = store.load()
        #expect(loaded.userData["steam:1"]?.lastPlayed == data.lastPlayed)
        #expect(loaded.userData["steam:1"]?.playTime == 3600)
        #expect(loaded.userData["steam:1"]?.profile.extraEnvironment == ["A": "1"])
        #expect(loaded.games.count == 1)
    }
}
