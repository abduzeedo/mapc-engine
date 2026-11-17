import Foundation

public enum BottleKind: String, Codable, Sendable, CaseIterable { case steam, epic, gog, amazon, ubisoft, ea }

/// A Wine prefix. One per store (plan §3).
public struct Bottle: Sendable, Equatable {
    public let kind: BottleKind
    public let url: URL

    public init(kind: BottleKind, paths: Paths) {
        self.kind = kind
        self.url = paths.bottle(kind.rawValue)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent("drive_c/windows").path) }
    public var driveC: URL { url.appendingPathComponent("drive_c") }
    /// Wine Mono (the .NET runtime) is installed in this bottle.
    public var hasMono: Bool { FileManager.default.fileExists(atPath: driveC.appendingPathComponent("windows/mono/mono-2.0").path) }
    public var steamDirectory: URL { driveC.appendingPathComponent("Program Files (x86)/Steam") }
    public var steamExecutable: URL { steamDirectory.appendingPathComponent("steam.exe") }
}

public extension Bottle {
    /// Maps a Windows path to the Mac. `C:` is the bottle's `drive_c`; other drives go where Wine's
    /// `dosdevices/<drive>` link points (`Z:` is the Mac's `/`, so a Steam library on the Mac's disk or an
    /// external drive is `Z:\Users\…` or `Z:\Volumes\…`). Nil for a drive the bottle doesn't have.
    func unixURL(forWindowsPath path: String) -> URL? {
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard let drive = parts.first?.lowercased(), drive.count == 2, drive.hasSuffix(":") else { return nil }
        let root: URL
        if drive == "c:" {
            root = driveC
        } else {
            let link = url.appendingPathComponent("dosdevices/\(drive)")
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
            root = URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
        }
        return parts.dropFirst().reduce(root) { $0.appendingPathComponent($1) }
    }
}

/// Creates Wine prefixes. Idempotent.
public struct BottleManager: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public func bottle(_ kind: BottleKind) -> Bottle { Bottle(kind: kind, paths: paths) }

    @discardableResult
    public func ensure(_ kind: BottleKind, engine: Engine) async throws -> Bottle {
        let bottle = Bottle(kind: kind, paths: paths)
        if bottle.exists { return bottle }
        try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        let boot: ProcessResult
        do {
            boot = try await ProcessRunner.run(engine.wine, ["wineboot", "--init"], environment: env)
        } catch {
            recordSetupFailure(kind, engine: engine, detail: "wine could not be started: \(error)")
            throw error
        }
        guard boot.succeeded, bottle.exists else {
            recordSetupFailure(kind, engine: engine, detail: "wineboot --init exited with status \(boot.status)"
                               + (bottle.exists ? "" : "; no Windows folder was created"), output: boot.output)
            throw WineRunnerError.launchFailed("couldn't create the \(kind.rawValue) environment")
        }
        // Command behaves like Ctrl, as Mac users expect in games.
        _ = try await ProcessRunner.run(
            engine.wine, ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "LeftCommandIsCtrl", "/d", "y", "/f"],
            environment: env)
        await WineRunner(paths: paths).applyFontLinks(engine: engine, bottle: bottle)
        return bottle
    }

    /// Why creating an environment failed, as `Logs/<store>-setup/<time>.log`. The error on screen says only that
    /// it failed, and nothing else was written: a report from a Mac whose Epic environment never got made had no
    /// log at all (2026-11-08). Problem reports pick up every folder under `Logs`. Returns the log, or nil if it
    /// couldn't be written.
    @discardableResult
    func recordSetupFailure(_ kind: BottleKind, engine: Engine, step: String? = nil, detail: String, output: String = "",
                            now: Date = Date()) -> URL? {
        guard let log = try? LogStore(paths: paths).newLog(for: "\(kind.rawValue)-setup", now: now) else { return nil }
        // The end of the output is where Wine says what went wrong.
        let kept = output.utf8.count > Self.setupLogBytes ? "[…]\n" + String(decoding: Array(output.utf8.suffix(Self.setupLogBytes)), as: UTF8.self) : output
        let text = "[MaPC] \(step ?? "Create \(kind.rawValue) environment") engine=\(engine.version): \(detail)\n\(kept)\n"
        guard (try? text.write(to: log, atomically: true, encoding: .utf8)) != nil else { return nil }
        return log
    }

    static let setupLogBytes = 64 << 10

    /// Stores whose environment holds only games, so nothing but a first Play creates it: Epic and GOG. Steam, Ubisoft
    /// and EA create theirs when their launcher is set up, and an empty one would hide that the launcher is missing.
    public static func createsEnvironmentOnPlay(_ store: StoreKind) -> Bool { store == .epic || store == .gog || store == .amazon }

    /// Gets a store's environment ready for a game. It's rebuilt when it is missing, for instance after a reset,
    /// so a reset never leaves a store unplayable. Does nothing for stores that set up their own launcher.
    @discardableResult
    public func prepareForPlay(_ store: StoreKind, engine: Engine) async throws -> Bottle? {
        guard Self.createsEnvironmentOnPlay(store) else { return nil }
        let bottle = try await ensure(store.bottleKind, engine: engine)
        provisionRuntime(in: store.bottleKind)
        return bottle
    }

    /// DLLs a fresh Wine prefix lacks and some games' plugins import (Moonlighter's Razer Chroma plugin
    /// needs the MFC runtime; without it `GameManager.Awake` throws and the screen stays black).
    /// Steam installs the Visual C++ runtime into its own bottle, so copy it from there when it exists.
    /// Nothing is downloaded; missing files are skipped, and existing ones are never overwritten.
    @discardableResult
    public func provisionRuntime(in kind: BottleKind) -> [String] {
        let fm = FileManager.default
        let target = Bottle(kind: kind, paths: paths)
        guard target.exists else { return [] }
        let dlls = ["mfc140u.dll", "mfcm140u.dll"]
        var copied: [String] = []
        for source in BottleKind.allCases where source != kind {
            let from = Bottle(kind: source, paths: paths)
            guard from.exists else { continue }
            for folder in ["system32", "syswow64"] {
                for dll in dlls {
                    let src = from.driveC.appendingPathComponent("windows/\(folder)/\(dll)")
                    let dst = target.driveC.appendingPathComponent("windows/\(folder)/\(dll)")
                    guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                    if (try? fm.copyItem(at: src, to: dst)) != nil { copied.append("\(folder)/\(dll)") }
                }
            }
        }
        return copied
    }
}
