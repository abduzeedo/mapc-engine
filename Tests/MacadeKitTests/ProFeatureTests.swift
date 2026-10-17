import Foundation
import Testing
@testable import MacadeKit

private func temp() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mapc-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
}

// MARK: Playtime

@Suite struct PlaytimeStatsTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }
    // Wednesday 2026-10-07 12:00 UTC
    let now = Date(timeIntervalSince1970: 1_791_374_400)
    let day: TimeInterval = 86_400

    func session(_ id: String, daysAgo: Double, hours: Double) -> PlaySession {
        PlaySession(gameID: id, start: now.addingTimeInterval(-daysAgo * day), duration: hours * 3600)
    }

    @Test func weekPeriodOnlyCountsThisCalendarWeek() {
        let sessions = [session("steam:1", daysAgo: 1, hours: 2), session("steam:1", daysAgo: 10, hours: 5)]
        let week = PlaytimeStats.perGame(sessions: sessions, allTime: [:], period: .week, now: now, calendar: calendar)
        #expect(week == [.init(gameID: "steam:1", seconds: 2 * 3600)])
    }

    @Test func allTimeUsesTheLargerOfSessionsAndLibraryTotal() {
        let sessions = [session("epic:a", daysAgo: 1, hours: 2)]
        let all = PlaytimeStats.perGame(sessions: sessions, allTime: ["epic:a": 50 * 3600, "gog:9": 3 * 3600],
                                        period: .allTime, now: now, calendar: calendar)
        #expect(all.map(\.gameID) == ["epic:a", "gog:9"])
        #expect(all[0].seconds == 50 * 3600)
    }

    @Test func rankingIsSortedAndTiesAreStable() {
        let sessions = [session("steam:2", daysAgo: 0.5, hours: 1), session("steam:1", daysAgo: 0.4, hours: 1), session("gog:3", daysAgo: 0.3, hours: 4)]
        let ranking = PlaytimeStats.perGame(sessions: sessions, allTime: [:], period: .week, now: now, calendar: calendar)
        #expect(ranking.map(\.gameID) == ["gog:3", "steam:1", "steam:2"])
    }

    @Test func storeTotalsAddUp() {
        let games = [PlaytimeStats.GameTotal(gameID: "steam:1", seconds: 100), .init(gameID: "steam:2", seconds: 50), .init(gameID: "epic:x", seconds: 120)]
        let stores = PlaytimeStats.perStore(games)
        #expect(stores == [.init(store: .steam, seconds: 150), .init(store: .epic, seconds: 120)].sorted { $0.seconds > $1.seconds })
    }

    @Test func weeklyIncludesEmptyWeeksOldestFirst() {
        let sessions = [session("steam:1", daysAgo: 1, hours: 2), session("steam:1", daysAgo: 15, hours: 3)]
        let weeks = PlaytimeStats.weekly(sessions: sessions, weeks: 4, now: now, calendar: calendar)
        #expect(weeks.count == 4)
        #expect(weeks.map(\.seconds) == [0, 3 * 3600, 0, 2 * 3600])
        #expect(weeks[0].weekStart < weeks[3].weekStart)
    }

    @Test func gameIDGivesStore() {
        #expect(PlaySession.store(of: "gog:1207658924") == .gog)
        #expect(PlaySession.store(of: "nonsense") == nil)
    }

    @Test func sessionStoreRoundTripsAndCaps() throws {
        let home = try temp(); defer { try? FileManager.default.removeItem(at: home) }
        let store = SessionStore(paths: Paths(home: home))
        let sessions = (0..<(SessionStore.maximumCount + 5)).map { PlaySession(gameID: "steam:\($0)", start: Date(timeIntervalSince1970: Double($0)), duration: 60) }
        store.save(sessions)
        let loaded = store.load()
        #expect(loaded.count == SessionStore.maximumCount)
        #expect(loaded.last?.gameID == sessions.last?.gameID)
    }
}

// MARK: Steam running app

@Suite struct SteamRunningAppTests {
    @Test func readsRunningApp() {
        let reg = "[Software\\\\Valve\\\\Steam] 1\n\"Rate\"=\"30000\"\n\"RunningAppID\"=dword:0003bb62\n\"SteamPath\"=\"c:/x\"\n"
        #expect(SteamRunningApp.parse(registry: Data(reg.utf8)) == "244578")
    }

    @Test func zeroOrMissingMeansNothingRunning() {
        #expect(SteamRunningApp.parse(registry: Data("\"RunningAppID\"=dword:00000000\n".utf8)) == nil)
        #expect(SteamRunningApp.parse(registry: Data("nothing here".utf8)) == nil)
        #expect(SteamRunningApp.parse(registry: Data("\"RunningAppID\"=dword:12".utf8)) == nil)
    }
}

// MARK: Saves

@Suite struct SaveTests {
    func roots(_ base: URL) -> SaveRoots {
        SaveRoots(profile: base.appendingPathComponent("users/me"), steamUserdata: base.appendingPathComponent("steam/userdata"),
                  install: base.appendingPathComponent("game"))
    }

    @Test func pathSafety() {
        #expect(SaveSource.isSafe("Cuphead"))
        #expect(SaveSource.isSafe("My Games/Foo"))
        #expect(!SaveSource.isSafe(""))
        #expect(!SaveSource.isSafe("../x"))
        #expect(!SaveSource.isSafe("a/../b"))
        #expect(!SaveSource.isSafe("/etc"))
        #expect(!SaveSource.isSafe("a//b"))
    }

    @Test func resolveStaysInsideAndRefusesLinks() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let r = roots(base)
        let roaming = base.appendingPathComponent("users/me/AppData/Roaming")
        try FileManager.default.createDirectory(at: roaming.appendingPathComponent("Cuphead"), withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: roaming.appendingPathComponent("Evil"), withDestinationURL: outside)

        #expect(r.resolve(SaveSource(root: .roaming, path: "Cuphead"))?.lastPathComponent == "Cuphead")
        #expect(r.resolve(SaveSource(root: .roaming, path: "Evil")) == nil)
        #expect(r.resolve(SaveSource(root: .roaming, path: "Evil/inner")) == nil)
        #expect(r.resolve(SaveSource(root: .roaming, path: "../Local")) == nil)
        #expect(r.resolve(SaveSource(root: .roaming, path: "New/Folder")) != nil)   // not there yet: fine for a restore
    }

    @Test func sourceForPickedFolder() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let r = roots(base)
        let folder = base.appendingPathComponent("users/me/AppData/LocalLow/Studio/Game")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(r.source(for: folder) == SaveSource(root: .localLow, path: "Studio/Game"))
        #expect(r.source(for: base.appendingPathComponent("elsewhere")) == nil)
    }

    @Test func locatorFindsByNameAndByRecentChange() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let r = roots(base)
        let old = Date(timeIntervalSinceNow: -86_400 * 30), recent = Date(timeIntervalSinceNow: -60)
        let profile = base.appendingPathComponent("users/me")
        try write("a", to: profile.appendingPathComponent("AppData/Roaming/The Witcher 3/user.settings"), modified: old)
        try write("b", to: profile.appendingPathComponent("AppData/LocalLow/Studio MDHR/Cuphead/save.dat"), modified: old)
        try write("c", to: profile.appendingPathComponent("AppData/Local/Mystery Dev/Mystery Game/slot1.sav"), modified: recent)
        try write("n", to: profile.appendingPathComponent("AppData/Local/Microsoft/cache.bin"), modified: recent)   // noise
        try write("t", to: profile.appendingPathComponent("AppData/Local/Temp/x.tmp"), modified: recent)           // noise
        try write("d", to: profile.appendingPathComponent("Documents/My Games/Some Game/profile.sav"), modified: recent)
        try write("e", to: base.appendingPathComponent("steam/userdata/12345/268910/remote/save.bin"), modified: old)
        try write("f", to: base.appendingPathComponent("game/Saves/slot.sav"), modified: old)

        let byName = SaveLocator.candidates(title: "The Witcher 3: Wild Hunt", steamAppID: nil, roots: r)
        #expect(byName.map(\.source) == [SaveSource(root: .roaming, path: "The Witcher 3"), SaveSource(root: .install, path: "Saves")])
        #expect(byName.first?.reason == .nameMatch)

        let cuphead = SaveLocator.candidates(title: "Cuphead", steamAppID: "268910", roots: r)
        #expect(cuphead.first?.reason == .steamCloud)
        #expect(cuphead.contains { $0.source == SaveSource(root: .localLow, path: "Studio MDHR/Cuphead") })

        let recentOnly = SaveLocator.candidates(title: "Unrelated Title", steamAppID: nil, roots: r, changedSince: Date(timeIntervalSinceNow: -3600))
        let ids = Set(recentOnly.map(\.source))
        #expect(ids.contains(SaveSource(root: .local, path: "Mystery Dev/Mystery Game")))
        #expect(ids.contains(SaveSource(root: .documents, path: "My Games/Some Game")))
        #expect(!ids.contains { $0.path.lowercased().contains("microsoft") || $0.path.lowercased().contains("temp") })
        #expect(recentOnly.allSatisfy { $0.reason != .nameMatch })
    }

    @Test func backupAndRestoreRoundTrip() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let r = roots(base)
        let save = base.appendingPathComponent("users/me/AppData/Roaming/Cuphead")
        try write("slot one", to: save.appendingPathComponent("slot1.sav"))
        try write("deep", to: save.appendingPathComponent("Profiles/a/b.dat"))
        try write("junk", to: save.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(at: save.appendingPathComponent("link"), withDestinationURL: base)   // must be skipped

        let destination = base.appendingPathComponent("iCloud")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = SaveBackupStore(destination: destination)
        let source = SaveSource(root: .roaming, path: "Cuphead")
        let backup = try store.create(gameID: "steam:268910", title: "Cuphead", sources: [source], roots: r, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(backup.files == 2)
        #expect(backup.sources == [source])
        #expect(store.list(gameID: "steam:268910", title: "Cuphead").map(\.id) == [backup.id])
        #expect(backup.folder.path.contains("MaPC Saves/Cuphead (steam-268910)"))

        // Progress is lost, a stray file appears, then restore.
        try write("slot one, later", to: save.appendingPathComponent("slot1.sav"))
        try write("extra", to: save.appendingPathComponent("slot2.sav"))
        try FileManager.default.removeItem(at: save.appendingPathComponent("Profiles"))
        let report = try store.restore(backup, roots: r, now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(report.files == 2)
        #expect(try String(contentsOf: save.appendingPathComponent("slot1.sav"), encoding: .utf8) == "slot one")
        #expect(try String(contentsOf: save.appendingPathComponent("Profiles/a/b.dat"), encoding: .utf8) == "deep")
        #expect(FileManager.default.fileExists(atPath: save.appendingPathComponent("slot2.sav").path))   // nothing deleted
        // The safety copy holds what was there before the restore.
        let safety = try #require(report.safetyBackup)
        #expect(safety.kind == .beforeRestore)
        #expect(try String(contentsOf: safety.folder.appendingPathComponent("data/0/slot1.sav"), encoding: .utf8) == "slot one, later")
        #expect(store.list(gameID: "steam:268910", title: "Cuphead").count == 2)
    }

    @Test func backupErrors() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let r = roots(base)
        let source = SaveSource(root: .roaming, path: "Nope")
        let missing = SaveBackupStore(destination: base.appendingPathComponent("nowhere"))
        #expect(throws: SaveBackupError.noSources) { try missing.create(gameID: "steam:1", title: "T", sources: [], roots: r) }
        #expect(throws: SaveBackupError.destinationUnavailable) { try missing.create(gameID: "steam:1", title: "T", sources: [source], roots: r) }
        let there = SaveBackupStore(destination: base)
        #expect(throws: SaveBackupError.nothingToBackUp) { try there.create(gameID: "steam:1", title: "T", sources: [source], roots: r) }
    }

    @Test func tamperedManifestIsRefused() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let r = roots(base)
        let save = base.appendingPathComponent("users/me/AppData/Roaming/G")
        try write("x", to: save.appendingPathComponent("a.sav"))
        let store = SaveBackupStore(destination: base)
        let backup = try store.create(gameID: "epic:g", title: "G", sources: [SaveSource(root: .roaming, path: "G")], roots: r)
        let manifestURL = backup.folder.appendingPathComponent("manifest.json")
        let evil = try String(contentsOf: manifestURL, encoding: .utf8).replacingOccurrences(of: "\"path\" : \"G\"", with: "\"path\" : \"..\\/..\\/escape\"")
        try evil.write(to: manifestURL, atomically: true, encoding: .utf8)
        let tampered = try #require(SaveBackupStore.read(backup.folder))
        #expect(tampered.sources.first?.path == "../../escape")
        #expect(throws: SaveBackupError.unsafeBackup) { try store.restore(tampered, roots: r) }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("users/escape").path))
    }

    @Test func oldBackupsArePruned() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let r = roots(base)
        try write("x", to: base.appendingPathComponent("users/me/AppData/Roaming/G/a.sav"))
        var store = SaveBackupStore(destination: base)
        store.maximumBackups = 3
        for i in 0..<5 {
            try store.create(gameID: "epic:g", title: "G", sources: [SaveSource(root: .roaming, path: "G")], roots: r,
                             now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 100))
        }
        #expect(store.list(gameID: "epic:g", title: "G").count == 3)
    }

    @Test func changeDetection() throws {
        let base = try temp(); defer { try? FileManager.default.removeItem(at: base) }
        let r = roots(base)
        try write("x", to: base.appendingPathComponent("users/me/AppData/Roaming/G/a.sav"), modified: Date(timeIntervalSinceNow: -1000))
        let s = [SaveSource(root: .roaming, path: "G")]
        #expect(!SaveBackupStore.hasChanges(sources: s, roots: r, since: Date(timeIntervalSinceNow: -500)))
        #expect(SaveBackupStore.hasChanges(sources: s, roots: r, since: Date(timeIntervalSinceNow: -2000)))
    }
}

// MARK: Links, shortcuts

@Suite struct GameLinkAndShortcutTests {
    @Test func linkRoundTrip() throws {
        let url = try #require(GameLink.playURL(gameID: "steam:268910"))
        #expect(url.scheme == "mapc")
        #expect(GameLink.gameID(from: url) == "steam:268910")
        #expect(GameLink.gameID(from: URL(string: "mapc://play?game=gog:1207658924")!) == "gog:1207658924")
    }

    @Test func linkRejectsAnythingElse() {
        for bad in ["mapc://play?game=nothing", "mapc://play?game=steam:", "mapc://play?game=steam:1%20;rm", "mapc://open?game=steam:1",
                    "http://play?game=steam:1", "mapc://play", "mapc://play?game=bogus:1", "mapc://play?game=steam:../../x"] {
            #expect(GameLink.gameID(from: URL(string: bad)!) == nil, "\(bad)")
        }
        #expect(GameLink.playURL(gameID: "steam:1'; rm -rf") == nil)
    }

    @Test func shortcutAppStructure() throws {
        let folder = try temp(); defer { try? FileManager.default.removeItem(at: folder) }
        let app = try ShortcutApp.create(title: "Hades: Edition/1", gameID: "epic:Sugar", in: folder)
        #expect(app.lastPathComponent == "Hades- Edition-1.app")
        let script = try String(contentsOf: app.appendingPathComponent("Contents/MacOS/launch"), encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("/usr/bin/open 'mapc://play?game="))
        let perms = try FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("Contents/MacOS/launch").path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
        #expect(ShortcutApp.existingGameID(at: app) == "epic:Sugar")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        #expect(plist?["LSUIElement"] as? Bool == true)
        #expect(plist?["CFBundleExecutable"] as? String == "launch")
        // Same game again replaces; a different app with that name is left alone.
        _ = try ShortcutApp.create(title: "Hades: Edition/1", gameID: "epic:Sugar", in: folder)
        let other = folder.appendingPathComponent("Taken.app/Contents")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(throws: ShortcutError.nameTaken("Taken.app")) { try ShortcutApp.create(title: "Taken", gameID: "gog:1", in: folder) }
        #expect(throws: ShortcutError.invalidGame) { try ShortcutApp.create(title: "X", gameID: "nonsense", in: folder) }
    }
}
