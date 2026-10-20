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

    @Test func manifestSkipsEnginesThatNeedANewerApp() throws {
        let json = #"""
        {"engines":[{"version":"1.0.0","url":"https://x/a","sha256":"aa","size":1,"backends":["dxvk"]},
                    {"version":"1.1.0","url":"https://x/b","sha256":"bb","size":1,"minAppVersion":"1.1.4","backends":["dxvk"]},
                    {"version":"2.0.2","url":"https://x/c","sha256":"cc","size":1,"minAppVersion":"0.1","backends":["d3dMetal"]}]}
        """#
        let m = try EngineManifest.decode(Data(json.utf8))
        #expect(m.usable(byApp: "1.1.3").latest(supporting: .dxvk)?.version == "1.0.0")
        #expect(m.usable(byApp: "1.1.4").latest(supporting: .dxvk)?.version == "1.1.0")
        #expect(m.usable(byApp: "1.1.10").latest(supporting: .dxvk)?.version == "1.1.0")
        #expect(m.usable(byApp: "1.1.3").latest(supporting: .d3dMetal)?.version == "2.0.2")
    }

    /// The live list after 2.0.1 was dropped (2.0.1 crashes at start on macOS 26), plus test-only entries.
    private func liveList(_ extra: String = "") throws -> EngineManifest {
        try EngineManifest.decode(Data(#"""
        {"engines":[{"version":"1.0.1","url":"https://x/a","sha256":"aa","size":1,"minAppVersion":"0.1","backends":["dxvk"]},
                    {"version":"2.0.2","url":"https://x/c","sha256":"cc","size":1,"minAppVersion":"1.0.1","backends":["d3dMetal","dxmt"]}\#(extra)]}
        """#.utf8))
    }
    private func info(_ version: String, _ backends: [String]) -> EngineInfo {
        EngineInfo(version: version, wineVersion: "11.0", backends: backends, minMacOS: "14.0")
    }

    @Test func droppedEngineIsReplacedByTheNewerOneWithTheSameBackends() throws {
        let updates = try liveList().updates(for: [info("2.0.1", ["d3dMetal", "dxmt"]), info("1.0.1", ["dxvk"])],
                                             appVersion: "1.1.5", macOS: "26.7.1")
        #expect(updates.map(\.installed) == ["2.0.1"])
        #expect(updates.first?.replacement.version == "2.0.2")
        // An older 2.x without DXMT is replaced too: 2.0.2 provides everything it did.
        #expect(try liveList().updates(for: [info("2.0.0", ["d3dMetal"])], appVersion: "1.1.5", macOS: "26.0")
            .first?.replacement.version == "2.0.2")
        // A dropped base engine goes to the newer base engine, not to 2.0.2, which has no DXVK.
        #expect(try liveList().updates(for: [info("1.0.0", ["dxvk"])], appVersion: "1.1.5", macOS: "26.0")
            .first?.replacement.version == "1.0.1")
    }

    @Test func listedNewerOrIrreplaceableEnginesAreLeftAlone() throws {
        let list = try liveList()
        // Still listed.
        #expect(list.updates(for: [info("2.0.2", ["d3dMetal", "dxmt"])], appVersion: "1.1.5", macOS: "26.7.1").isEmpty)
        // Newer than anything listed (a private test build).
        #expect(list.updates(for: [info("2.0.4-test", ["d3dMetal", "dxmt"])], appVersion: "1.1.5", macOS: "26.7.1").isEmpty)
        // Nothing listed provides its backend.
        #expect(list.updates(for: [info("0.9.0", ["vkd3d"])], appVersion: "1.1.5", macOS: "26.7.1").isEmpty)
        // Nothing installed.
        #expect(list.updates(for: [], appVersion: "1.1.5", macOS: "26.7.1").isEmpty)
    }

    @Test func replacementMustFitThisAppAndMacOS() throws {
        let newer = #",{"version":"2.0.3","url":"https://x/d","sha256":"dd","size":1,"minAppVersion":"1.2.0","minMacOS":"27.0","backends":["d3dMetal","dxmt"]}"#
        let old = [info("2.0.1", ["d3dMetal", "dxmt"])]
        // 2.0.3 needs app 1.2.0 and macOS 27, so 1.1.5 on macOS 26 gets 2.0.2.
        #expect(try liveList(newer).updates(for: old, appVersion: "1.1.5", macOS: "26.7.1").first?.replacement.version == "2.0.2")
        #expect(try liveList(newer).updates(for: old, appVersion: "1.2.0", macOS: "26.7.1").first?.replacement.version == "2.0.2")
        #expect(try liveList(newer).updates(for: old, appVersion: "1.2.0", macOS: "27.0").first?.replacement.version == "2.0.3")
        // An app too old for every replacement is offered none (1.0.0 can't use 2.0.2).
        #expect(try liveList().updates(for: old, appVersion: "1.0.0", macOS: "26.7.1").isEmpty)
        // An engine listed only for newer apps is still listed, so it isn't "dropped".
        #expect(try liveList(newer).updates(for: [info("2.0.3", ["d3dMetal", "dxmt"])], appVersion: "1.1.5", macOS: "26.7.1").isEmpty)
    }

    @Test func replacedEngineEnvironmentsMoveToTheReplacement() {
        var s = AppSettings()
        s.activeEngineVersion = "1.0.1"
        s.bottleEngines = ["steam": "2.0.1", "epic": "1.0.1", "gog": "2.0.1"]
        s.moveEnvironments(fromEngine: "2.0.1", to: "2.0.2")
        #expect(s.bottleEngines == ["steam": "2.0.2", "epic": "1.0.1", "gog": "2.0.2"])
        #expect(s.activeEngineVersion == "1.0.1")
        s.activeEngineVersion = "2.0.1"
        s.moveEnvironments(fromEngine: "2.0.1", to: "2.0.2")
        #expect(s.activeEngineVersion == "2.0.2")
        var fresh = AppSettings()   // settings from before environments were recorded
        fresh.moveEnvironments(fromEngine: "2.0.1", to: "2.0.2")
        #expect(fresh.bottleEngines == nil && fresh.activeEngineVersion == nil)
    }

    @Test func entryFitsComparesVersionsNumerically() {
        let e = EngineManifest.Entry(version: "2.0.2", url: URL(string: "https://x")!, sha256: "", size: 0,
                                     minAppVersion: "1.1.10", backends: nil, minMacOS: "26.10")
        #expect(e.fits(appVersion: "1.1.10", macOS: "26.10.1"))
        #expect(!e.fits(appVersion: "1.1.9", macOS: "26.10"))
        #expect(!e.fits(appVersion: "1.2", macOS: "26.9"))
        #expect(EngineManifest.macOSVersion.split(separator: ".").count == 3)
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
