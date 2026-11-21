import Foundation
import Testing
@testable import MacadeKit

@Suite struct PathsTests {
    @Test func explicitHomeRedirectsEverything() {
        let home = URL(fileURLWithPath: "/tmp/macade-test", isDirectory: true)
        let p = Paths(home: home)
        #expect(p.engine(version: "1.0.0").path == "/tmp/macade-test/Engines/1.0.0")
        #expect(p.bottle("steam").path == "/tmp/macade-test/Bottles/steam")
        #expect(p.libraryFile.path == "/tmp/macade-test/Library.json")
        #expect(p.gameLogs("steam:570").lastPathComponent == "steam-570")
    }

    @Test func createsDirectories() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let p = Paths(home: home)
        try p.createDirectories()
        for dir in [p.engines, p.tools, p.bottles, p.artwork, p.logs] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        }
    }
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputAndStatus() async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo one; echo two 1>&2; exit 3"])
        #expect(r.status == 3)
        #expect(Set(r.output.split(separator: "\n")) == ["one", "two"])
    }

    @Test func streamsLines() async throws {
        let seen = Box()
        _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'a\\nb\\n'"]) { line in
            if case let .stdout(s) = line { seen.add(s) }
        }
        #expect(seen.values == ["a", "b"])
    }

    @Test func cancellationTerminatesProcess() async throws {
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let r = try await task.value
        #expect(r.status != 0)
    }

    @Test func launchFailureThrows() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/binary"))
        }
    }

    @Test func lineSplitterKeepsPartialLines() {
        let s = LineSplitter()
        #expect(s.feed(Data("ab".utf8)).isEmpty)
        #expect(s.feed(Data("c\nde".utf8)) == ["abc"])
        #expect(s.feed(Data("f\n".utf8)) == ["def"])
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite struct LogStoreTests {
    @Test func rotatesKeepingNewest() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LogStore(paths: Paths(home: home), keep: 3)
        for i in 0..<6 {
            _ = try store.newLog(for: "epic:Foo", now: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
        }
        let logs = store.logs(for: "epic:Foo")
        #expect(logs.count == 3)
        #expect(logs[0].lastPathComponent > logs[2].lastPathComponent)
    }

    /// A user wrote that logs took too much space; single logs reached 6.4 GB.
    @Test func tidyTrimsBigFinishedLogsAndRemovesOldOnes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        var store = LogStore(paths: Paths(home: home))
        store.trimAbove = 4096
        store.headBytes = 100
        store.tailBytes = 200
        let now = Date()
        let fm = FileManager.default
        func write(_ game: String, _ name: String, _ text: String, age: TimeInterval) throws -> URL {
            let dir = Paths(home: home).gameLogs(game)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let spam = String(repeating: "[mvk-warn] VkDescriptorPool exhausted\n", count: 500)
        let finished = try write("gog-1", "a.log", "[MaPC] Launch engine=1.0.1\n" + spam + "wine: Unhandled page fault\n[MaPC] Exit status=5\n", age: 60)
        let running = try write("steam", "b.log", "[MaPC] Launch engine=2.0.2\n" + spam, age: 60)
        let old = try write("epic-Old", "c.log", "[MaPC] Launch\n[MaPC] Exit status=0\n", age: 40 * 86_400)

        store.tidy(now: now)

        let trimmed = try String(contentsOf: finished, encoding: .utf8)
        #expect(trimmed.hasPrefix("[MaPC] Launch engine=1.0.1"))
        #expect(trimmed.contains("[MaPC] Trimmed"))
        #expect(trimmed.hasSuffix("wine: Unhandled page fault\n[MaPC] Exit status=5\n"))
        #expect(trimmed.utf8.count < 1024)
        #expect(LogDiagnosis(log: trimmed).launch?.status == 5)
        #expect(try String(contentsOf: running, encoding: .utf8).utf8.count > 4096)   // may still be written to
        #expect(!fm.fileExists(atPath: old.path))
        #expect(!fm.fileExists(atPath: old.deletingLastPathComponent().path))       // empty folder removed
    }

    @Test func excerptReturnsTail() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LogStore(paths: Paths(home: home))
        let url = try store.newLog(for: "steam:1")
        try (1...100).map(String.init).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(store.excerpt(of: url, lines: 3) == "98\n99\n100")
    }
}

@Suite struct SystemCheckTests {
    @Test func reportsThisMachine() async {
        let r = await SystemCheck().run()
        #expect(r.appleSilicon == .ok)
        #expect(r.macOS == .ok)
    }
}

@Suite struct EnvironmentsLocationTests {
    func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mapc-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func defaultIsInHome() {
        let p = Paths(home: URL(fileURLWithPath: "/tmp/macade-test", isDirectory: true), environmentsFolder: nil)
        #expect(p.bottles.path == "/tmp/macade-test/Bottles")
        #expect(p.environmentsAvailable)
    }

    @Test func pickedFolderHoldsTheEnvironments() throws {
        let folder = try tempDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let p = Paths(home: URL(fileURLWithPath: "/tmp/macade-test", isDirectory: true), environmentsFolder: folder)
        #expect(p.bottle("steam").path == folder.appendingPathComponent("MaPC Environments/steam").path)
        #expect(p.environmentsAvailable)
    }

    @Test func missingDriveIsUnavailableAndNothingIsCreated() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let gone = URL(fileURLWithPath: "/Volumes/MaPC-Test-\(UUID().uuidString)/Games", isDirectory: true)
        let p = Paths(home: home, environmentsFolder: gone)
        #expect(!p.environmentsAvailable)
        #expect(p.environmentsDriveName == gone.pathComponents[2])
        try p.createDirectories()          // must not try to make the missing drive's folders
        #expect(!FileManager.default.fileExists(atPath: p.bottles.path))
    }

    @Test func readsTheSavedFolderFromSettings() throws {
        let home = try tempDir(), folder = try tempDir()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: folder) }
        var settings = AppSettings()
        settings.environmentsFolder = folder
        try JSONStore<AppSettings>(url: home.appendingPathComponent("Settings.json")).save(settings)
        #expect(Paths(home: home).environmentsFolder?.standardizedFileURL == folder.standardizedFileURL)
        #expect(Paths(home: home).bottles.path == Paths.bottles(in: folder).path)
    }

    func makeEnvironment(_ bottles: URL, _ name: String) throws {
        let fm = FileManager.default
        let env = bottles.appendingPathComponent(name)
        try fm.createDirectory(at: env.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: env.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: env.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try fm.createSymbolicLink(atPath: env.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try Data("save".utf8).write(to: env.appendingPathComponent("drive_c/save.dat"))
    }

    @Test func copiesKeepingLinksAndLeavesOriginalsUntilAsked() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Bottles"), destination = Paths.bottles(in: root.appendingPathComponent("SSD"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("SSD"), withIntermediateDirectories: true)
        try makeEnvironment(source, "steam")
        try makeEnvironment(source, "epic")
        let checked = try EnvironmentMover.plan(from: source, to: destination)
        #expect(checked.names == ["epic", "steam"])
        // Force the cross-drive path (ditto), which a temporary folder can't reach otherwise.
        let plan = EnvironmentMover.Plan(source: source, destination: destination, names: checked.names, sameVolume: false)
        try await EnvironmentMover.move(plan)
        let fm = FileManager.default
        for name in ["steam", "epic"] {
            let env = destination.appendingPathComponent(name)
            #expect(try fm.destinationOfSymbolicLink(atPath: env.appendingPathComponent("dosdevices/z:").path) == "/")
            #expect(try fm.destinationOfSymbolicLink(atPath: env.appendingPathComponent("dosdevices/c:").path) == "../drive_c")
            #expect(fm.fileExists(atPath: env.appendingPathComponent("drive_c/save.dat").path))
            #expect(fm.fileExists(atPath: source.appendingPathComponent(name).path))
        }
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent(".steam.moving").path))
        EnvironmentMover.removeOriginals(plan)
        #expect(EnvironmentMover.environmentNames(in: source).isEmpty)
    }

    @Test func movesBackAndTidiesTheEmptyFolder() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let picked = Paths.bottles(in: root), home = root.appendingPathComponent("Home/Bottles")
        try makeEnvironment(picked, "steam")
        let plan = try EnvironmentMover.plan(from: picked, to: home)
        #expect(plan.sameVolume)
        try await EnvironmentMover.move(plan)
        EnvironmentMover.removeOriginals(plan)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("steam/drive_c/save.dat").path))
        #expect(!FileManager.default.fileExists(atPath: picked.path))
    }

    @Test func refusesToOverwriteOrNest() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Bottles"), destination = Paths.bottles(in: root)
        try makeEnvironment(source, "steam")
        try makeEnvironment(destination, "steam")
        #expect(throws: EnvironmentMoveError.alreadyThere("Steam")) { try EnvironmentMover.plan(from: source, to: destination) }
        #expect(throws: EnvironmentMoveError.nested) {
            try EnvironmentMover.plan(from: source, to: Paths.bottles(in: source.appendingPathComponent("steam")))
        }
    }
}
