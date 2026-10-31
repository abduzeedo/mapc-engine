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
        async let list = json(["list", "--platform", "Windows", "--json"])
        async let installed = json(["list-installed", "--json"])
        return try LegendaryParser.games(listJSON: try await list, installedJSON: try await installed)
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
        let r = try await ProcessRunner.run(
            legendary,
            ["install", game.storeID, "--platform", "Windows", "--base-path", gamesFolder.path, "-y", "--skip-sdl"],
            environment: environment
        ) { line in
            switch line {
            case .stdout(let s), .stderr(let s): if let p = LegendaryParser.progress(from: s) { onProgress(p) }
            }
        }
        guard r.succeeded else { throw EpicError.commandFailed("The install didn't finish. You can resume it.") }
    }

    /// Installs the update Epic released for an installed game, in place. legendary won't start a game that has
    /// one (`Game is out of date`). Cancelling stops the download; running again resumes it.
    public func update(_ game: Game, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let r = try await ProcessRunner.run(legendary, ["update", game.storeID, "-y", "--skip-sdl"], environment: environment) { line in
            switch line {
            case .stdout(let s), .stderr(let s): if let p = LegendaryParser.progress(from: s) { onProgress(p) }
            }
        }
        guard r.succeeded else { throw EpicError.commandFailed("The update didn't finish. You can resume it.") }
    }

    /// The text legendary prints when a game has an update it must install before launching.
    public static func needsUpdate(launchOutput: String) -> Bool { launchOutput.contains("Game is out of date") }

    public func uninstall(_ game: Game) async throws {
        let r = try await run(["uninstall", game.storeID, "-y"])
        guard r.succeeded else { throw EpicError.commandFailed("Couldn't uninstall \(game.title).") }
    }

    /// Launches through Legendary with Macade's Wine, so Epic's own auth tokens never touch our logs.
    @discardableResult
    public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                     onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        guard isSignedIn else { throw EpicError.notSignedIn }
        return try runner.launch(
            program: legendary,
            arguments: ["launch", game.storeID, "--wine", engine.wine.path, "--wine-prefix", bottle.url.path] + profile.extraArguments,
            engine: engine, bottle: bottle, profile: profile,
            extraEnvironment: ["LEGENDARY_CONFIG_PATH": paths.legendaryConfig.path],
            logID: game.id, onExit: onExit)
    }

    // MARK: Helpers

    private func run(_ args: [String]) async throws -> ProcessResult {
        guard isLegendaryInstalled else { throw EpicError.legendaryMissing }
        return try await ProcessRunner.run(legendary, args, environment: environment)
    }

    private func json(_ args: [String]) async throws -> Data {
        guard isLegendaryInstalled else { throw EpicError.legendaryMissing }
        // Capture stdout only: legendary logs to stderr and the JSON must stay clean.
        let process = Process()
        process.executableURL = legendary
        process.arguments = args
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        // Nothing reads stderr, so it can't be a pipe: once legendary writes ~64 KB there it would block forever.
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    process.terminationStatus == 0
                        ? cont.resume(returning: data)
                        : cont.resume(throwing: EpicError.commandFailed("Couldn't read your Epic library."))
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}
