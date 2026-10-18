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
        try await BottleManager(paths: paths).ensure(.steam, engine: engine)
        let (tmp, response) = try await URLSession.shared.download(from: Self.setupURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WineRunnerError.launchFailed("couldn't download the Steam installer") }
        let installer = paths.home.appendingPathComponent("SteamSetup.exe")
        try? FileManager.default.removeItem(at: installer)
        try FileManager.default.moveItem(at: tmp, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        _ = try await ProcessRunner.run(engine.wine, [installer.path, "/S"], environment: env)
        guard isSteamInstalled else { throw WineRunnerError.launchFailed("Steam did not install") }
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
