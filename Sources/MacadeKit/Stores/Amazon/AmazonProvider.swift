import Foundation
import CryptoKit

public enum AmazonError: Error, LocalizedError {
    case helperMissing
    case notSignedIn
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .helperMissing: "The Amazon Games helper isn't installed yet."
        case .notSignedIn: "You're not signed in to Amazon."
        case .failed(let m): m
        }
    }
}

/// Amazon Games through Nile, Heroic's command-line Amazon client (GPL-3.0), run as a separate program.
/// Amazon's own Windows launcher is never used. Games start directly from their own files (`fuel.json`).
public struct AmazonProvider: StoreProvider, Sendable {
    /// Pinned download (Nile's release, Apple Silicon). SHA-256 is verified before it is ever run.
    public static let nileVersion = "1.2.0"
    public static let nileURL = URL(string: "https://github.com/imLinguin/nile/releases/download/v1.2.0/nile_macOS_arm64")!
    public static let nileSHA256 = "6cc74eb19117c8c309b0b94657e1e267642a3b4840d7386a133dcf6f3bffeab0"

    /// What Amazon's login page needs; Nile makes a fresh device identity and PKCE verifier for each sign-in.
    public struct LoginRequest: Decodable, Sendable {
        public let client_id: String
        public let code_verifier: String
        public let serial: String
        public let url: URL
    }

    public let kind = StoreKind.amazon
    public let paths: Paths
    let runner: WineRunner
    private let gamesRoot: URL?

    public init(paths: Paths, gamesFolder: URL? = nil) {
        self.paths = paths
        self.runner = WineRunner(paths: paths)
        self.gamesRoot = gamesFolder
    }

    public var nile: URL { paths.tools.appendingPathComponent("nile") }
    public var bottle: Bottle { Bottle(kind: .amazon, paths: paths) }
    public var gamesFolder: URL { (gamesRoot ?? paths.defaultGamesFolder).appendingPathComponent("Amazon", isDirectory: true) }
    /// Nile adds `nile` to `NILE_CONFIG_PATH`.
    var configFolder: URL { paths.amazonConfig.appendingPathComponent("nile", isDirectory: true) }
    var userFile: URL { configFolder.appendingPathComponent("user.json") }
    var libraryFile: URL { configFolder.appendingPathComponent("library.json") }
    var installedFile: URL { configFolder.appendingPathComponent("installed.json") }
    public var isHelperInstalled: Bool { FileManager.default.isExecutableFile(atPath: nile.path) }
    public var isSignedIn: Bool { FileManager.default.fileExists(atPath: userFile.path) }

    private var environment: [String: String] {
        ["NILE_CONFIG_PATH": paths.amazonConfig.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    }

    // MARK: Setup

    public func installHelper() async throws {
        try paths.createDirectories()
        let (tmp, response) = try await URLSession.shared.download(from: Self.nileURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AmazonError.failed("Couldn't download the Amazon Games helper.") }
        let digest = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.nileSHA256 else { throw AmazonError.failed("The downloaded Amazon Games helper failed its integrity check.") }
        try? FileManager.default.removeItem(at: nile)
        try FileManager.default.moveItem(at: tmp, to: nile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nile.path)
    }

    // MARK: Account

    /// Starts a sign-in: the page to show, and what `signIn(code:request:)` needs afterwards.
    public func loginRequest() async throws -> LoginRequest {
        let out = try await stdout(["auth", "--login", "--non-interactive"])
        guard let request = try? JSONDecoder().decode(LoginRequest.self, from: out) else {
            throw AmazonError.failed("Couldn't start the Amazon sign-in.")
        }
        return request
    }

    /// Registers this device with the code from Amazon's login redirect. The code is never logged.
    public func signIn(code: String, request: LoginRequest) async throws {
        _ = try await stdout(["register", "--code", code.trimmingCharacters(in: .whitespacesAndNewlines),
                              "--client-id", request.client_id, "--code-verifier", request.code_verifier,
                              "--serial", request.serial])
        guard isSignedIn else { throw AmazonError.failed("Amazon sign-in failed. Please try again.") }
        for file in [userFile, libraryFile] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Deregisters this device with Amazon, then forgets the account locally either way.
    public func signOut() async {
        _ = try? await stdout(["auth", "--logout"])
        try? FileManager.default.removeItem(at: userFile)
        try? FileManager.default.removeItem(at: libraryFile)
    }

    // MARK: Library

    public func refresh() async throws -> [Game] {
        guard isHelperInstalled else { throw AmazonError.helperMissing }
        guard isSignedIn else { throw AmazonError.notSignedIn }
        _ = try await stdout(["library", "sync"])
        guard let data = try? Data(contentsOf: libraryFile) else { throw AmazonError.failed("Couldn't read your Amazon library.") }
        let installed = AmazonParser.installed((try? Data(contentsOf: installedFile)) ?? Data())
        return AmazonParser.library(data).map { item in
            let path = installed[item.id]
            return Game(store: .amazon, storeID: item.id, title: item.title,
                        isInstalled: path.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                        installPath: path,
                        sizeOnDisk: path.flatMap { GOGProvider.folderSize($0) },
                        coverURL: item.cover, heroURL: item.background)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: Install / play

    /// Downloads and installs the game. Cancelling stops it; running again resumes.
    public func install(_ game: Game, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard isSignedIn else { throw AmazonError.notSignedIn }
        try FileManager.default.createDirectory(at: gamesFolder, withIntermediateDirectories: true)
        let r = try await ProcessRunner.run(nile, ["install", game.storeID, "--base-path", gamesFolder.path],
                                            environment: environment) { line in
            switch line {
            case .stdout(let s), .stderr(let s): if let p = GOGParser.progress(from: s) { onProgress(p) }
            }
        }
        guard r.succeeded, installPath(game.storeID) != nil else {
            throw AmazonError.failed("The install didn't finish. You can resume it.")
        }
    }

    /// Nile deletes only the files its manifest installed (saves the game wrote are kept).
    public func uninstall(_ game: Game) async throws {
        let r = try await ProcessRunner.run(nile, ["uninstall", game.storeID], environment: environment) { _ in }
        guard r.succeeded else { throw AmazonError.failed("Couldn't uninstall \(game.title).") }
    }

    /// Starts the game's `fuel.json` command in the Amazon environment, with the variables Amazon's
    /// game SDK reads (the same ones Nile sets).
    @discardableResult
    public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                     onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        guard let folder = installPath(game.storeID),
              let data = try? Data(contentsOf: folder.appendingPathComponent("fuel.json")),
              let task = AmazonParser.fuel(data) else {
            throw AmazonError.failed("Couldn't find how to start \(game.title). Try reinstalling it.")
        }
        func local(_ windowsPath: String) -> URL {
            windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).reduce(folder) { $0.appendingPathComponent(String($1)) }
        }
        var profile = profile
        let sdk = configFolder.appendingPathComponent("SDK/Amazon Games Services", isDirectory: true)
        profile.extraEnvironment["FUEL_DIR"] = sdk.appendingPathComponent("Legacy").path
        profile.extraEnvironment["AMAZON_GAMES_SDK_PATH"] = sdk.appendingPathComponent("AmazonGamesSDK").path
        profile.extraEnvironment["AMAZON_GAMES_FUEL_ENTITLEMENT_ID"] = game.storeID
        if let sku = AmazonParser.sku((try? Data(contentsOf: libraryFile)) ?? Data(), id: game.storeID) {
            profile.extraEnvironment["AMAZON_GAMES_FUEL_PRODUCT_SKU"] = sku
        }
        return try runner.run(engine: engine, bottle: bottle, executable: local(task.path).path,
                              arguments: task.arguments + profile.extraArguments,
                              workingDirectory: task.workingDirectory.map(local) ?? folder,
                              profile: profile, logID: game.id, onExit: onExit)
    }

    // MARK: Helpers

    func installPath(_ id: String) -> URL? {
        AmazonParser.installed((try? Data(contentsOf: installedFile)) ?? Data())[id]
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Runs Nile and returns stdout only (it logs to stderr, and its JSON must stay clean).
    private func stdout(_ args: [String]) async throws -> Data {
        guard isHelperInstalled else { throw AmazonError.helperMissing }
        let process = Process()
        process.executableURL = nile
        process.arguments = args
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    cont.resume(returning: data)
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}
