import Foundation
import CryptoKit

public enum EpicError: Error, LocalizedError {
    case legendaryMissing
    case notSignedIn
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .legendaryMissing: "The Epic helper isn't installed yet."
        case .notSignedIn: "You're not signed in to Epic Games."
        case .commandFailed(let m): m
        }
    }
}

/// Epic Games through Legendary, a command-line client that runs natively. The Epic launcher is never used.
public struct EpicProvider: StoreProvider, Sendable {
    /// Pinned download (Heroic's maintained build, Apple Silicon). SHA-256 is verified.
    public static let legendaryVersion = "0.20.43"
    public static let legendaryURL = URL(string: "https://github.com/Heroic-Games-Launcher/legendary/releases/download/0.20.43/legendary_macOS_arm64")!
    public static let legendarySHA256 = "fce325ca0c6c7edd7aaed559ed3f09772689f7f259965ca9ba5fb90f4b5108eb"
    public static let loginURL = URL(string: "https://legendary.gl/epiclogin")!

    public let kind = StoreKind.epic
    public let paths: Paths
    let runner: WineRunner
    private let gamesRoot: URL?

    public init(paths: Paths, gamesFolder: URL? = nil) {
        self.paths = paths
        self.runner = WineRunner(paths: paths)
        self.gamesRoot = gamesFolder
    }

    public var legendary: URL { paths.tools.appendingPathComponent("legendary") }
    public var bottle: Bottle { Bottle(kind: .epic, paths: paths) }
    public var gamesFolder: URL { (gamesRoot ?? paths.defaultGamesFolder).appendingPathComponent("Epic", isDirectory: true) }
    public var isLegendaryInstalled: Bool { FileManager.default.isExecutableFile(atPath: legendary.path) }
    public var isSignedIn: Bool { FileManager.default.fileExists(atPath: paths.legendaryConfig.appendingPathComponent("user.json").path) }

    var environment: [String: String] {
        var env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        env["LEGENDARY_CONFIG_PATH"] = paths.legendaryConfig.path
        return env
    }

    // MARK: Setup

    public func installLegendary() async throws {
        try paths.createDirectories()
        let (tmp, response) = try await URLSession.shared.download(from: Self.legendaryURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EpicError.commandFailed("Couldn't download the Epic helper.") }
        let digest = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.legendarySHA256 else { throw EpicError.commandFailed("The downloaded Epic helper failed its integrity check.") }
        try? FileManager.default.removeItem(at: legendary)
        try FileManager.default.moveItem(at: tmp, to: legendary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legendary.path)
    }

    // MARK: Account

    /// Completes sign-in with the `authorizationCode` from Epic's login redirect. The code is never logged.
    public func signIn(authorizationCode code: String) async throws {
        let r = try await run(["auth", "--code", code.trimmingCharacters(in: .whitespacesAndNewlines)])
        guard r.succeeded, isSignedIn else { throw EpicError.commandFailed("Epic sign-in failed. Please try again.") }
    }

    public func signOut() async throws {
        _ = try await run(["auth", "--delete"])
    }

    // MARK: Library

    public func refresh() async throws -> [Game] {
        guard isLegendaryInstalled else { throw EpicError.legendaryMissing }
        guard isSignedIn else { throw EpicError.notSignedIn }
        async let list = libraryList()
        async let installed = json(["list-installed", "--json"])
        return try LegendaryParser.games(listJSON: try await list, installedJSON: try await installed)
    }

    /// Epic's answer for a big library (1,059 items in a 2026-11-09 report) takes longer than legendary's default
    /// 10 s API timeout, so the list failed for that account while a 93-game one worked. Wait up to a minute, and
    /// try once more, since the server can also be slow once. Legendary's output goes to `Logs/epic/`.
    func libraryList() async throws -> Data {
        let args = Self.apiTimeoutArguments + ["list", "--platform", "Windows", "--json"]
        do { return try await json(args, logTo: try? runner.logs.newLog(for: kind.rawValue)) }
        catch EpicError.commandFailed {
            return try await json(args, logTo: try? runner.logs.newLog(for: kind.rawValue))
        }
    }

    static let apiTimeout = 60

    /// Put before the command on every legendary run that talks to Epic. `install`, `update` and `launch` fetch the
    /// whole library's asset list again before they start (legendary's `get_game(update_meta=True)` and
    /// `get_asset(update=True)`), so on a big library they hit the same 10 s timeout as `list`: a 1,043-game account
    /// failed every install while its 91-game backup installed the same game (2026-11-10 report).
    static var apiTimeoutArguments: [String] { ["--api-timeout", "\(apiTimeout)"] }

    /// What to tell the user from the end of legendary's error output: a timeout says so, anything else names the
    /// last error line (an exception, "Error:"), cut short. Only that line is shown, never the whole output.
    static func failureSummary(fromLog log: String, base: String = "Couldn't read your Epic library.") -> String {
        if log.contains("ReadTimeout") || log.contains("timed out") {
            return base + " Epic took too long to answer. Try again in a minute."
        }
        let last = log.split(whereSeparator: \.isNewline).last { $0.contains("Error") || $0.contains("Exception") }
        guard let last else { return base }
        let line = last.trimmingCharacters(in: .whitespaces)
        return base + " " + (line.count > 160 ? String(line.prefix(160)) + "…" : line)
    }

    /// Games already downloaded, readable without the network.
    public func installedGames() async -> [Game] {
        guard isLegendaryInstalled, isSignedIn else { return [] }
        return (try? await refresh()) ?? []
    }

    // MARK: Install / play

    /// Downloads and installs. Cancelling the task stops the download; running again resumes it. `--skip-sdl`:
    /// legendary runs with no stdin attached, so a title with optional packs (e.g. language packs) would otherwise
    /// stop to prompt for which to install and crash on EOF; this installs only the required data instead.
    public func install(_ game: Game, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: gamesFolder, withIntermediateDirectories: true)
        try await download(game, ["install", game.storeID, "--platform", "Windows", "--base-path", gamesFolder.path, "-y", "--skip-sdl"],
                           failure: "The install didn't finish. You can resume it.", onProgress: onProgress)
    }

    /// Installs the update Epic released for an installed game, in place. legendary won't start a game that has
    /// one (`Game is out of date`). Cancelling stops the download; running again resumes it.
    public func update(_ game: Game, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(game, ["update", game.storeID, "-y", "--skip-sdl"],
                           failure: "The update didn't finish. You can resume it.", onProgress: onProgress)
    }

    /// Runs an install or update. legendary's output, without the download's per-second progress lines, goes to
    /// `Logs/epic-install/` so a failed install says why in a problem report. Not the game's own log folder: that
    /// one's newest log is what Check Last Launch and the update offer read. The error shown names a timeout or
    /// legendary's last error line.
    private func download(_ game: Game, _ args: [String], failure: String,
                          onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard isLegendaryInstalled else { throw EpicError.legendaryMissing }
        let log = try? runner.logs.newLog(for: Self.installLogID)
        let handle = log.flatMap { try? FileHandle(forWritingTo: $0) }
        defer { try? handle?.close() }
        let stamp = { ISO8601DateFormatter().string(from: Date()) }
        try? handle?.write(contentsOf: Data("[MaPC] Launch \(stamp()) legendary=\(Self.legendaryVersion) command=\(args[0]) game=\(game.storeID)\n".utf8))
        let r = try await ProcessRunner.run(legendary, Self.apiTimeoutArguments + args, environment: environment) { line in
            switch line {
            case .stdout(let s), .stderr(let s):
                if let p = LegendaryParser.progress(from: s) { onProgress(p) }
                if !LegendaryParser.isProgressDetail(s) { try? handle?.write(contentsOf: Data((s + "\n").utf8)) }
            }
        }
        try? handle?.write(contentsOf: Data("\n[MaPC] Exit \(stamp()) status=\(r.status)\n".utf8))
        guard r.succeeded else {
            let summary = Self.failureSummary(fromLog: String(r.output.suffix(8192)), base: failure)
            throw EpicError.commandFailed(summary)
        }
    }

    static let installLogID = "epic-install"

    /// The text legendary prints when a game has an update it must install before launching.
    public static func needsUpdate(launchOutput: String) -> Bool { launchOutput.contains("Game is out of date") }

    public func uninstall(_ game: Game) async throws {
        let r = try await run(Self.apiTimeoutArguments + ["uninstall", game.storeID, "-y"])
        guard r.succeeded else { throw EpicError.commandFailed("Couldn't uninstall \(game.title).") }
    }

    /// Launches through Legendary with Macade's Wine, so Epic's own auth tokens never touch our logs.
    @discardableResult
    public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                     onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        guard isSignedIn else { throw EpicError.notSignedIn }
        return try runner.launch(
            program: legendary,
            arguments: Self.apiTimeoutArguments + ["launch", game.storeID, "--wine", engine.wine.path, "--wine-prefix", bottle.url.path] + profile.extraArguments,
            engine: engine, bottle: bottle, profile: profile,
            extraEnvironment: ["LEGENDARY_CONFIG_PATH": paths.legendaryConfig.path],
            logID: game.id, onExit: onExit)
    }

    // MARK: Helpers

    private func run(_ args: [String]) async throws -> ProcessResult {
        guard isLegendaryInstalled else { throw EpicError.legendaryMissing }
        return try await ProcessRunner.run(legendary, args, environment: environment)
    }

    private func json(_ args: [String], logTo log: URL? = nil) async throws -> Data {
        guard isLegendaryInstalled else { throw EpicError.legendaryMissing }
        // Capture stdout only: legendary logs to stderr and the JSON must stay clean.
        let process = Process()
        process.executableURL = legendary
        process.arguments = args
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        // Nothing reads stderr, so it can't be a pipe: once legendary writes ~64 KB there it would block forever.
        // It goes to the run's log file when there is one (the command's arguments aren't written, only its name).
        let logHandle = log.flatMap { try? FileHandle(forWritingTo: $0) }
        process.standardError = logHandle ?? FileHandle.nullDevice
        let stamp = { ISO8601DateFormatter().string(from: Date()) }
        let command = args.first { !$0.hasPrefix("-") && Int($0) == nil } ?? "?"
        try? logHandle?.write(contentsOf: Data("[MaPC] Launch \(stamp()) legendary=\(Self.legendaryVersion) command=\(command)\n".utf8))
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                defer { try? logHandle?.close() }
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    try? logHandle?.write(contentsOf: Data("\n[MaPC] Exit \(stamp()) status=\(process.terminationStatus)\n".utf8))
                    if process.terminationStatus == 0 { return cont.resume(returning: data) }
                    let text = log.map { LogStore.tail(of: $0, bytes: 8192) } ?? ""
                    cont.resume(throwing: EpicError.commandFailed(Self.failureSummary(fromLog: text)))
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}
