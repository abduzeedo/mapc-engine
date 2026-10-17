import Foundation

/// A store whose own Windows launcher runs inside its environment, like Steam: Ubisoft Connect and
/// the EA app. Macade downloads the official installer from the store, installs the launcher, finds
/// the games it installed, and starts them through it (the launchers handle accounts and DRM).
public struct LauncherStore: StoreProvider, Sendable {
    public let kind: StoreKind
    public let paths: Paths
    let runner: WineRunner

    public init(kind: StoreKind, paths: Paths) {
        precondition(kind == .ubisoft || kind == .ea, "LauncherStore is for Ubisoft and EA")
        self.kind = kind
        self.paths = paths
        self.runner = WineRunner(paths: paths)
    }

    public var bottle: Bottle { Bottle(kind: kind.bottleKind, paths: paths) }

    /// Official installers, downloaded over HTTPS from each publisher's CDN at setup time.
    public var installerURL: URL {
        switch kind {
        case .ubisoft: URL(string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe")!
        default: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!
        }
    }

    /// Ubisoft's installer runs silently; EA's shows its own setup window, so the user can follow it.
    var installerArguments: [String] { kind == .ubisoft ? ["/S"] : [] }

    /// The EA app embeds CEF (not Qt WebEngine, so the `QTWEBENGINE_*` variables don't reach it). Its GPU
    /// process crashes under D3DMetal (no `IDXGIResource::GetSharedHandle`) and the window stays dark
    /// blue, so it renders in software. CEF reads these switches from the app's own command line.
    var launcherArguments: [String] { kind == .ea ? ["--disable-gpu", "--disable-gpu-compositing"] : [] }

    /// The launcher's own executable inside the environment.
    public var launcherExecutable: URL {
        switch kind {
        case .ubisoft: bottle.driveC.appendingPathComponent("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe")
        default: Self.eaExecutable(in: bottle)
        }
    }

    /// The EA app keeps each version in its own folder, `EA Desktop\<version>\EA Desktop\EADesktop.exe`, and
    /// makes a junction `EA Desktop\EA Desktop` to the newest. Wine doesn't create that junction (it leaves an
    /// empty folder), so find the newest version folder ourselves.
    static func eaExecutable(in bottle: Bottle) -> URL {
        let root = bottle.driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop")
        let fm = FileManager.default
        let newest = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { fm.fileExists(atPath: root.appendingPathComponent("\($0)/EA Desktop/EADesktop.exe").path) }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
        return root.appendingPathComponent("\(newest ?? "EA Desktop")/EA Desktop/EADesktop.exe")
    }

    public var isLauncherInstalled: Bool { FileManager.default.fileExists(atPath: launcherExecutable.path) }

    // MARK: Setup

    /// Creates the environment, downloads the official installer and runs it. Returns when the
    /// installer exits; the launcher may still finish its own first-run update afterwards.
    public func installLauncher(engine: Engine) async throws {
        try await BottleManager(paths: paths).ensure(kind.bottleKind, engine: engine)
        // The EA app's installer has a .NET custom action; without Wine Mono it fails with error 1603.
        try await WineMono(paths: paths).ensureInstalled(in: bottle, engine: engine)
        let (tmp, response) = try await URLSession.shared.download(from: installerURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WineRunnerError.launchFailed("couldn't download the \(kind.displayName) installer")
        }
        let installer = paths.home.appendingPathComponent("\(kind.rawValue)-setup.exe")
        try? FileManager.default.removeItem(at: installer)
        try FileManager.default.moveItem(at: tmp, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        _ = try await ProcessRunner.run(engine.wine, [installer.path] + installerArguments, environment: env)
        guard isLauncherInstalled else { throw WineRunnerError.launchFailed("\(kind.displayName) did not install") }
    }

    // MARK: Library

    public func refresh() async throws -> [Game] {
        switch kind {
        case .ubisoft: Self.ubisoftGames(systemReg: (try? String(contentsOf: bottle.url.appendingPathComponent("system.reg"), encoding: .utf8)) ?? "",
                                         bottle: bottle)
        default: Self.eaGames(in: bottle)
        }
    }

    /// Ubisoft Connect records installs under `HKLM\Software\Wow6432Node\Ubisoft\Launcher\Installs\<id>`.
    static func ubisoftGames(systemReg: String, bottle: Bottle) -> [Game] {
        var games: [Game] = []
        var currentID: String?
        let header = #"[Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\"#
        for raw in systemReg.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("[") {
                currentID = nil
                if line.lowercased().hasPrefix(header.lowercased()) {
                    let rest = line.dropFirst(header.count)
                    let id = rest.prefix { $0 != "]" }
                    if !id.isEmpty, !id.contains("\\") { currentID = String(id) }
                }
            } else if let id = currentID, line.lowercased().hasPrefix(#""installdir"=""#) {
                let value = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                let windowsPath = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .replacingOccurrences(of: #"\\"#, with: "/")
                guard let dir = bottle.unixURL(forWindowsPath: windowsPath) else { continue }
                let title = dir.lastPathComponent
                guard !title.isEmpty, FileManager.default.fileExists(atPath: dir.path) else { continue }
                games.append(Game(store: .ubisoft, storeID: id, title: title, isInstalled: true,
                                  installPath: dir, sizeOnDisk: GOGProvider.folderSize(dir)))
            }
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The EA app installs into `C:\Program Files\EA Games\<Game>`, with `__Installer\installerdata.xml`.
    static func eaGames(in bottle: Bottle) -> [Game] {
        let root = bottle.driveC.appendingPathComponent("Program Files/EA Games")
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("__Installer").path) }
            .map { dir in
                let xml = (try? String(contentsOf: dir.appendingPathComponent("__Installer/installerdata.xml"), encoding: .utf8)) ?? ""
                let id = eaContentID(installerXML: xml) ?? dir.lastPathComponent
                return Game(store: .ea, storeID: id, title: dir.lastPathComponent, isInstalled: true,
                            installPath: dir, sizeOnDisk: GOGProvider.folderSize(dir))
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// First `<contentID>` in the game's installer data, which the EA app accepts in launch links.
    static func eaContentID(installerXML: String) -> String? {
        guard let start = installerXML.range(of: "<contentID>"),
              let end = installerXML.range(of: "</contentID>", range: start.upperBound..<installerXML.endIndex) else { return nil }
        let id = installerXML[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    // MARK: Launching

    /// Opens the launcher window.
    @discardableResult
    public func launchLauncher(engine: Engine, profile: LaunchProfile = LaunchProfile(),
                               onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        try start([], engine: engine, profile: profile, logID: kind.rawValue, onExit: onExit)
    }

    /// Asks the launcher to start the game (it signs in, checks for updates, then runs it).
    @discardableResult
    public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                     onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        let link = kind == .ubisoft
            ? "uplay://launch/\(game.storeID)/0"
            : "link2ea://launchgame/\(game.storeID)?platform=PCWIN"
        return try start([link] + profile.extraArguments, engine: engine, profile: profile, logID: game.id, onExit: onExit)
    }

    private func start(_ arguments: [String], engine: Engine, profile: LaunchProfile, logID: String,
                       onExit: (@Sendable (Int32) -> Void)?) throws -> RunningProcess {
        guard isLauncherInstalled else { throw WineRunnerError.launchFailed("\(kind.displayName) isn't installed") }
        // Both launchers embed Chromium, which needs the same no-GPU flags as Steam's web helper.
        var profile = profile
        profile.extraEnvironment = SteamProvider.webEngineEnvironment.merging(profile.extraEnvironment) { _, user in user }
        return try runner.run(engine: engine, bottle: bottle, executable: launcherExecutable.path,
                              arguments: launcherArguments + arguments,
                              workingDirectory: launcherExecutable.deletingLastPathComponent(), profile: profile,
                              logID: logID, onExit: onExit)
    }
}
