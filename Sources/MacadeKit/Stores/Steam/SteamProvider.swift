import Foundation

public struct SteamProvider: StoreProvider, Sendable {
    public static let setupURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Steam command line, found in the Phase 0 spike. The 2026 client ignores `-cef-*` flags,
    /// so rendering is fixed by the helper wrapper instead. Remote-overridable later.
    public static let defaultArguments = ["-no-cef-sandbox"]
    static let overrides = ["bcrypt=b;ncrypt=b", "gameoverlayrenderer,gameoverlayrenderer64=d"]

    /// Games inherit Steam's environment. Many launchers (e.g. CD Projekt's REDlauncher) embed Qt
    /// WebEngine, a Chromium that crashes with GPU compositing under Wine, like Steam's own UI did.
    static let webEngineEnvironment = [
        "QTWEBENGINE_CHROMIUM_FLAGS": "--disable-gpu --disable-gpu-compositing --in-process-gpu --no-sandbox",
        "QTWEBENGINE_DISABLE_SANDBOX": "1",
    ]

    public let kind = StoreKind.steam
    public let paths: Paths
    let runner: WineRunner

    public init(paths: Paths) {
        self.paths = paths
        self.runner = WineRunner(paths: paths)
    }

    public var bottle: Bottle { Bottle(kind: .steam, paths: paths) }
    public var isSteamInstalled: Bool { FileManager.default.fileExists(atPath: bottle.steamExecutable.path) }

    /// The installer only supplies a bootstrapper. Never skip verification until the actual client
    /// and its interface exist. Repair explicitly verifies even an apparently complete installation.
    public var isClientReady: Bool {
        let fm = FileManager.default
        let dir = bottle.steamDirectory
        let core = ["steamclient.dll", "steamclient64.dll"].contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        let ui = fm.fileExists(atPath: dir.appendingPathComponent("clientui").path)
        let cef = dir.appendingPathComponent("bin/cef")
        let helpers = (try? fm.contentsOfDirectory(at: cef, includingPropertiesForKeys: nil)) ?? []
        return core && ui && helpers.contains { folder in
            ["steamwebhelper.exe", "steamwebhelper_real.exe"].contains { name in
                let size = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.size] as? Int ?? 0
                return size > 500_000
            }
        }
    }

    func arguments(verifyFiles: Bool = false) -> [String] {
        Self.defaultArguments + (isClientReady && !verifyFiles ? ["-noverifyfiles"] : [])
    }

    public func refresh() async throws -> [Game] { SteamLibrary.scan(bottle: bottle) }

    // MARK: Setup

    /// Creates the bottle, downloads Valve's installer and installs Steam silently.
    public func installSteam(engine: Engine) async throws {
        // The Steam environment may already exist from an earlier try, and then nothing below would start Wine
        // through a path that checks these. Same questions as a launch gets (`WineRunner.launch`).
        if engine.isDamaged { throw WineRunnerError.engineDamaged(version: engine.version, missing: engine.missingCoreFiles) }
        if !SystemCheck.rosettaIsInstalled() { throw WineRunnerError.rosettaMissing }
        try await BottleManager(paths: paths).ensure(.steam, engine: engine)
        let (tmp, response) = try await URLSession.shared.download(from: Self.setupURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            recordInstallFailure(engine: engine, detail: "the installer download returned HTTP \(status)")
            throw WineRunnerError.launchFailed("couldn't download the Steam installer")
        }
        let installer = paths.home.appendingPathComponent("SteamSetup.exe")
        try? FileManager.default.removeItem(at: installer)
        try FileManager.default.moveItem(at: tmp, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }
        try await runInstaller(installer, engine: engine)
    }

    /// Runs Valve's installer in the Steam environment and checks that Steam is there afterwards. When it isn't, why
    /// goes to `Logs/steam-setup/<time>.log`. Before, the installer's output and exit status were dropped: a report
    /// from a Mac where Steam never installed (MaPC 1.1.27, 2026-11-10) had no log at all to say what happened.
    func runInstaller(_ installer: URL, engine: Engine) async throws {
        // A download a network filter replaced (an error page, a cut-off file) isn't a Windows program.
        guard Self.isWindowsProgram(installer) else {
            recordInstallFailure(engine: engine, detail: "the downloaded installer isn't a Windows program: \(Self.describe(installer))")
            throw WineRunnerError.launchFailed("the Steam installer download was damaged or blocked; try again, or on another network")
        }
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(engine.wine, [installer.path, "/S"], environment: env)
        } catch {
            recordInstallFailure(engine: engine, detail: "wine could not be started: \(error)")
            throw error
        }
        // The installer can hand the work to another process and exit first; wait for the environment to settle.
        if !isSteamInstalled { await waitForEnvironment(engine: engine, environment: env) }
        guard isSteamInstalled else {
            recordInstallFailure(engine: engine, detail: "SteamSetup.exe /S exited with status \(result.status) and no steam.exe appeared. "
                                 + "Installer \(Self.describe(installer)). \(installedFiles())", output: result.output)
            throw WineRunnerError.launchFailed("Steam did not install")
        }
    }

    /// `wineserver -w`: returns once nothing runs in the environment. Bounded, so a stuck process can't hang setup.
    private func waitForEnvironment(engine: Engine, environment: [String: String], seconds: UInt64 = 120) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await ProcessRunner.run(engine.wineserver, ["-w"], environment: environment) }
            group.addTask { try? await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func recordInstallFailure(engine: Engine, detail: String, output: String = "") {
        BottleManager(paths: paths).recordSetupFailure(.steam, engine: engine, step: "Install Steam", detail: detail, output: output)
    }

    /// What the Steam folder holds after a failed install, so the log tells "nothing was written" from "written elsewhere".
    private func installedFiles() -> String {
        let fm = FileManager.default
        let programFiles = bottle.driveC.appendingPathComponent("Program Files (x86)")
        guard fm.fileExists(atPath: programFiles.path) else { return "drive_c has no Program Files (x86) folder." }
        guard let names = try? fm.contentsOfDirectory(atPath: bottle.steamDirectory.path) else {
            return "No Steam folder in Program Files (x86)."
        }
        return "Steam folder holds: " + (names.isEmpty ? "nothing" : names.sorted().prefix(30).joined(separator: ", "))
    }

    /// A Windows program starts with "MZ".
    static func isWindowsProgram(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data("MZ".utf8)
    }

    /// Size and first bytes of a file, for a setup log.
    static func describe(_ file: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? -1
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 16)
        } ?? Data()
        let printable = String(decoding: head, as: UTF8.self).map { $0.isASCII && !$0.isNewline ? $0 : "." }
        return "\(size) bytes, starts with \"\(String(printable))\""
    }

    // MARK: Launching

    /// Steam changes its CEF directory between client versions and updates restore Valve's helper,
    /// so the wrapper is re-applied before every launch.
    @discardableResult
    public func ensureWebHelperWrapper(engine: Engine) throws -> [String] {
        let fm = FileManager.default
        let cefRoot = bottle.steamDirectory.appendingPathComponent("bin/cef")
        let folders = ((try? fm.contentsOfDirectory(at: cefRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("cef.") }
        guard !folders.isEmpty else { return [] } // the bootstrapper has no helper yet
        guard let wrapper = ChromiumHelperWrapper.wrapper(in: engine)
                ?? fm.contents(atPath: engine.steamWebHelperWrapper.path), !wrapper.isEmpty else {
            throw WineRunnerError.launchFailed("the Steam interface helper is missing from the engine")
        }
        var changed: [String] = []
        for dir in folders {
            if try ChromiumHelperWrapper.wrap(dir.appendingPathComponent("steamwebhelper.exe"), with: wrapper, legacyWrapper: true) {
                changed.append(dir.lastPathComponent)
            }
        }
        return changed
    }

    /// Opens the Steam window.
    @discardableResult
    public func launchSteam(engine: Engine, profile: LaunchProfile = LaunchProfile(), verifyFiles: Bool = false,
                            onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        try start(arguments: arguments(verifyFiles: verifyFiles), engine: engine, profile: profile, logID: "steam", onExit: onExit)
    }

    /// Starts Steam if needed and launches the game.
    @discardableResult
    public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                     onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        try start(arguments: ["-silent"] + arguments() + ["-applaunch", game.storeID] + profile.extraArguments,
                  engine: engine, profile: profile, logID: game.id, onExit: onExit)
    }

    /// Asks a running Steam to quit cleanly. Must use the engine Steam is running under.
    @discardableResult
    public func shutdown(engine: Engine) throws -> RunningProcess {
        try runner.run(engine: engine, bottle: bottle, executable: "Steam.exe", arguments: ["-shutdown"],
                       workingDirectory: bottle.steamDirectory, logID: "steam", onExit: nil)
    }

    /// Opens Steam's install dialog for an app.
    @discardableResult
    public func install(appID: String, engine: Engine) throws -> RunningProcess {
        try start(arguments: arguments() + ["steam://install/\(appID)"], engine: engine,
                  profile: LaunchProfile(), logID: "steam", onExit: nil)
    }

    private func start(arguments: [String], engine: Engine, profile: LaunchProfile, logID: String,
                       onExit: (@Sendable (Int32) -> Void)?) throws -> RunningProcess {
        if arguments.contains("-noverifyfiles") { try ensureWebHelperWrapper(engine: engine) }
        var profile = profile
        profile.extraEnvironment = Self.webEngineEnvironment.merging(profile.extraEnvironment) { _, user in user }
        return try runner.run(engine: engine, bottle: bottle, executable: "Steam.exe", arguments: arguments,
                              workingDirectory: bottle.steamDirectory, profile: profile,
                              extraOverrides: Self.overrides, logID: logID, onExit: onExit)
    }
}
