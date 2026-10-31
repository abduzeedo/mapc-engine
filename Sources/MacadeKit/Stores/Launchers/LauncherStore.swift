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

    /// Ubisoft's installer runs silently; EA's shows its own setup window, so the user can follow it. EA's would
    /// then open the EA app itself, without `launcherArguments` and `launcherEnvironment`, and the app lets one
    /// copy run: Open would only bring up that broken window. `EAX_LAUNCH_CLIENT` is the installer's own switch.
    var installerArguments: [String] { kind == .ubisoft ? ["/S"] : ["EAX_LAUNCH_CLIENT=0"] }

    /// The EA app is a Qt Quick window with CEF in child windows (not Qt WebEngine, so the `QTWEBENGINE_*`
    /// variables don't reach it). CEF reads these switches from the app's own command line: it renders in
    /// software, and in-process, since Wine on the Mac doesn't show what CEF's GPU process draws into the app's
    /// window (the page stayed black, though it took clicks). Tested 2026-10-30 on EA app 13.813.
    var launcherArguments: [String] {
        kind == .ea ? ["--disable-gpu", "--disable-gpu-compositing", "--in-process-gpu"] : []
    }

    /// Qt Quick draws the EA app's window through Direct3D, which on the Mac is a Metal layer over the whole
    /// window, CEF's child windows included: the window stayed dark blue. Drawn in software, Qt and CEF share
    /// the window. Qt reads the older `QMLSCENE_DEVICE` first: with only `QT_QUICK_BACKEND`, the app still drew
    /// through Direct3D on the D3DMetal engine (2026-10-30). Games the EA app starts inherit both; they only
    /// change Qt Quick programs.
    var launcherEnvironment: [String: String] {
        kind == .ea ? ["QT_QUICK_BACKEND": "software", "QMLSCENE_DEVICE": "softwarecontext"] : [:]
    }

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
        await prepare(engine: engine)
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
                return Game(store: .ea, storeID: id, title: eaTitle(installerXML: xml) ?? dir.lastPathComponent, isInstalled: true,
                            installPath: dir, sizeOnDisk: GOGProvider.folderSize(dir))
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The game's name in its installer data, US English first: the folder name is shortened ("Jedi Fallen Order"
    /// for "STAR WARS Jedi - Fallen Order™"), and the full one is what finds the game's artwork on Steam.
    static func eaTitle(installerXML: String) -> String? {
        let pattern = #"<gameTitle\b([^>]*)>([^<]*)</gameTitle>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = installerXML as NSString
        let titles: [(attributes: String, title: String)] = regex
            .matches(in: installerXML, range: NSRange(location: 0, length: text.length))
            .map { (text.substring(with: $0.range(at: 1)), text.substring(with: $0.range(at: 2))) }
            .map { ($0.0, $0.1.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
        return (titles.first { $0.attributes.contains(#"locale="en_US""#) } ?? titles.first)?.title
    }

    /// First `<contentID>` in the game's installer data, which the EA app accepts in launch links.
    static func eaContentID(installerXML: String) -> String? {
        guard let start = installerXML.range(of: "<contentID>"),
              let end = installerXML.range(of: "</contentID>", range: start.upperBound..<installerXML.endIndex) else { return nil }
        let id = installerXML[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    // MARK: Launching

    /// What the environment needs before the launcher starts: for EA, the roots its game installers are signed under
    /// (`EASigningRoots`). Call it before `launchLauncher` and `play`; it does nothing once they're there.
    public func prepare(engine: Engine) async {
        guard kind == .ea, bottle.exists else { return }
        await EASigningRoots.ensure(in: bottle, engine: engine)
    }

    /// Opens the launcher window.
    @discardableResult
    public func launchLauncher(engine: Engine, profile: LaunchProfile = LaunchProfile(),
                               onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        try start([], engine: engine, profile: profile, logID: kind.rawValue, onExit: onExit)
    }

    /// Starts the game. An EA game with a program named in its installer data runs that program directly, with the
    /// game's own profile: it asks the running EA app for its license, which finds the offer itself, and goes on
    /// (2026-10-30, EA app 13.813). The EA app must already be running (`launchLauncher`), or the game starts it
    /// without `launcherArguments`. Launch links are the fallback: this EA app takes only offer IDs in them
    /// ("There are no valid keys in the launchGameRequest" for a content ID), and nothing on disk names the offer.
    @discardableResult
    public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                     onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        if let program = gameProgram(game) {
            return try runner.run(engine: engine, bottle: bottle, executable: program.path, arguments: profile.extraArguments,
                                  workingDirectory: program.deletingLastPathComponent(), profile: profile,
                                  logID: game.id, onExit: onExit)
        }
        let link = kind == .ubisoft
            ? "uplay://launch/\(game.storeID)/0"
            : "link2ea://launchgame/\(game.storeID)?platform=PCWIN"
        return try start([link] + profile.extraArguments, engine: engine, profile: profile, logID: game.id, onExit: onExit)
    }

    /// The program an installed EA game runs, from its installer data, when it's there.
    public func gameProgram(_ game: Game) -> URL? {
        guard kind == .ea, let folder = game.installPath,
              let xml = try? String(contentsOf: folder.appendingPathComponent("__Installer/installerdata.xml"), encoding: .utf8)
        else { return nil }
        return Self.eaPrograms(installerXML: xml).lazy
            .map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The game's programs in its installer data (`<runtime><launcher><filePath>`), as paths inside the game's
    /// folder, 64-bit first and trials left out. The path starts with the registry value holding the install folder,
    /// `[HKEY_LOCAL_MACHINE\SOFTWARE\Respawn\Jedi Fallen Order\Install Dir]SwGame\...`: what follows is relative to it.
    static func eaPrograms(installerXML: String) -> [String] {
        let pattern = #"<launcher\b[^>]*>(.*?)</launcher>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        let text = installerXML as NSString
        func value(_ tag: String, in block: String) -> String? {
            guard let open = block.range(of: "<\(tag)>"), let close = block.range(of: "</\(tag)>", range: open.upperBound..<block.endIndex)
            else { return nil }
            return block[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let launchers = regex.matches(in: installerXML, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) }
            .filter { value("trial", in: $0) != "1" }
        let ordered = launchers.filter { value("requires64BitOS", in: $0) == "1" } + launchers.filter { value("requires64BitOS", in: $0) != "1" }
        return ordered.compactMap { block -> String? in
            guard var path = value("filePath", in: block) else { return nil }
            if path.hasPrefix("["), let end = path.firstIndex(of: "]") { path = String(path[path.index(after: end)...]) }
            path = path.replacingOccurrences(of: "\\", with: "/")
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.split(separator: "/").contains("..") else { return nil }
            return path
        }
    }

    private func start(_ arguments: [String], engine: Engine, profile: LaunchProfile, logID: String,
                       onExit: (@Sendable (Int32) -> Void)?) throws -> RunningProcess {
        guard isLauncherInstalled else { throw WineRunnerError.launchFailed("\(kind.displayName) isn't installed") }
        // Both launchers embed Chromium, which needs the same no-GPU flags as Steam's web helper.
        var profile = profile
        profile.extraEnvironment = SteamProvider.webEngineEnvironment.merging(launcherEnvironment) { _, own in own }
            .merging(profile.extraEnvironment) { _, user in user }
        return try runner.run(engine: engine, bottle: bottle, executable: launcherExecutable.path,
                              arguments: launcherArguments + arguments,
                              workingDirectory: launcherExecutable.deletingLastPathComponent(), profile: profile,
                              logID: logID, onExit: onExit)
    }
}
