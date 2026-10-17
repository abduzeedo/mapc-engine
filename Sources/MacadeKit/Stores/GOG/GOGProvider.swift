import Foundation
import CryptoKit

public enum GOGError: Error, LocalizedError {
    case helperMissing
    case notSignedIn
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .helperMissing: "The GOG helper isn't installed yet."
        case .notSignedIn: "You're not signed in to GOG."
        case .failed(let m): m
        }
    }
}

/// GOG through gogdl, Heroic's command-line GOG client (GPL-3.0), run as a separate program.
/// GOG Galaxy is never used. Games are DRM-free and start directly from their own files.
public struct GOGProvider: StoreProvider, Sendable {
    /// Pinned download (Heroic's release, Apple Silicon). SHA-256 is verified before it is ever run.
    public static let gogdlVersion = "1.3.0"
    public static let gogdlURL = URL(string: "https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/v1.3.0/gogdl_macos_arm64")!
    public static let gogdlSHA256 = "a85ae9ef80a3e7840b19a416dd4b3c5db2054508c6147315f1c22faa63a29b38"
    /// GOG's own login page; its redirect carries a one-time code that gogdl exchanges for tokens.
    public static let loginURL = URL(string: "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=client2")!

    public let kind = StoreKind.gog
    public let paths: Paths
    let runner: WineRunner
    private let gamesRoot: URL?

    public init(paths: Paths, gamesFolder: URL? = nil) {
        self.paths = paths
        self.runner = WineRunner(paths: paths)
        self.gamesRoot = gamesFolder
    }

    public var gogdl: URL { paths.tools.appendingPathComponent("gogdl") }
    public var bottle: Bottle { Bottle(kind: .gog, paths: paths) }
    public var gamesFolder: URL { (gamesRoot ?? paths.defaultGamesFolder).appendingPathComponent("GOG", isDirectory: true) }
    var authFile: URL { paths.gogConfig.appendingPathComponent("auth.json") }
    var installedFile: URL { paths.gogConfig.appendingPathComponent("installed.json") }
    var artworkFile: URL { paths.gogConfig.appendingPathComponent("artwork.json") }
    public var isHelperInstalled: Bool { FileManager.default.isExecutableFile(atPath: gogdl.path) }
    public var isSignedIn: Bool { FileManager.default.fileExists(atPath: authFile.path) }

    private var environment: [String: String] {
        ["GOGDL_CONFIG_PATH": paths.gogConfig.path, "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    }

    // MARK: Setup

    public func installHelper() async throws {
        try paths.createDirectories()
        let (tmp, response) = try await URLSession.shared.download(from: Self.gogdlURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GOGError.failed("Couldn't download the GOG helper.") }
        let digest = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.gogdlSHA256 else { throw GOGError.failed("The downloaded GOG helper failed its integrity check.") }
        try? FileManager.default.removeItem(at: gogdl)
        try FileManager.default.moveItem(at: tmp, to: gogdl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gogdl.path)
    }

    // MARK: Account

    /// Exchanges the code from GOG's login redirect for tokens. The code is never logged.
    public func signIn(code: String) async throws {
        let out = try await stdout(["--auth-config-path", authFile.path, "auth", "--code", code.trimmingCharacters(in: .whitespacesAndNewlines)])
        guard GOGParser.credentials(out) != nil, isSignedIn else {
            try? FileManager.default.removeItem(at: authFile)
            throw GOGError.failed("GOG sign-in failed. Please try again.")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
    }

    public func signOut() {
        try? FileManager.default.removeItem(at: authFile)
    }

    // MARK: Library

    public func refresh() async throws -> [Game] {
        guard isHelperInstalled else { throw GOGError.helperMissing }
        guard isSignedIn else { throw GOGError.notSignedIn }
        guard let token = GOGParser.credentials(try await stdout(["--auth-config-path", authFile.path, "auth"]))?.access_token else {
            throw GOGError.failed("GOG asked to sign in again.")
        }
        var owned: [(id: String, title: String)] = []
        var page = 1, pages = 1
        repeat {
            var request = URLRequest(url: URL(string: "https://embed.gog.com/account/getFilteredProducts?mediaType=1&sortBy=title&page=\(page)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GOGError.failed("Couldn't read your GOG library.") }
            let result = try GOGParser.products(data)
            owned += result.games
            pages = result.totalPages
            page += 1
        } while page <= pages && page <= 50

        let art = await artwork(for: owned.map(\.id))
        let installed = loadInstalled().games
        return owned.map { item in
            let entry = installed[item.id]
            return Game(store: .gog, storeID: item.id, title: entry?.title ?? item.title,
                        isInstalled: entry.map { FileManager.default.fileExists(atPath: $0.path.path) } ?? false,
                        installPath: entry?.path,
                        sizeOnDisk: entry.flatMap { Self.folderSize($0.path) },
                        coverURL: art[item.id]?.cover, heroURL: art[item.id]?.background)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Covers and backgrounds from GOG's games database, cached on disk (they rarely change).
    private func artwork(for ids: [String]) async -> [String: GOGParser.Artwork] {
        var cache = (try? JSONDecoder().decode([String: GOGParser.Artwork].self, from: Data(contentsOf: artworkFile))) ?? [:]
        let missing = ids.filter { cache[$0] == nil }
        await withTaskGroup(of: (String, GOGParser.Artwork?).self) { group in
            var next = missing.makeIterator()
            func add() {
                guard let id = next.next() else { return }
                group.addTask {
                    let url = URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/\(id)")!
                    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return (id, nil) }
                    return (id, GOGParser.artwork(data))
                }
            }
            for _ in 0..<8 { add() }
            for await (id, art) in group {
                if let art { cache[id] = art }
                add()
            }
        }
        try? JSONEncoder().encode(cache).write(to: artworkFile, options: .atomic)
        return cache
    }

    // MARK: Install / play

    /// Downloads and installs the Windows version. Cancelling stops it; running again resumes.
    public func install(_ game: Game, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard isSignedIn else { throw GOGError.notSignedIn }
        try FileManager.default.createDirectory(at: gamesFolder, withIntermediateDirectories: true)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: gamesFolder.path)) ?? [])
        let r = try await ProcessRunner.run(
            gogdl,
            ["--auth-config-path", authFile.path, "download", game.storeID, "--platform", "windows",
             "--path", gamesFolder.path, "--skip-dlcs", "--lang", "en-US"],
            environment: environment
        ) { line in
            switch line {
            case .stdout(let s), .stderr(let s): if let p = GOGParser.progress(from: s) { onProgress(p) }
            }
        }
        guard r.succeeded, let folder = findInstall(id: game.storeID, preferring: before) else {
            throw GOGError.failed("The install didn't finish. You can resume it.")
        }
        var installed = loadInstalled()
        installed.games[game.storeID] = .init(title: game.title, path: folder)
        try saveInstalled(installed)
    }

    public func uninstall(_ game: Game) throws {
        var installed = loadInstalled()
        if let entry = installed.games[game.storeID] {
            // Only ever delete inside Macade's GOG folder.
            if entry.path.standardizedFileURL.path.hasPrefix(gamesFolder.standardizedFileURL.path + "/") {
                try FileManager.default.removeItem(at: entry.path)
            }
            installed.games[game.storeID] = nil
            try saveInstalled(installed)
        }
    }

    /// Starts the game's primary play task in the GOG environment.
    @discardableResult
    public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                     onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        guard let folder = loadInstalled().games[game.storeID]?.path,
              let data = try? Data(contentsOf: folder.appendingPathComponent("goggame-\(game.storeID).info")),
              let task = GOGParser.playTask(infoJSON: data) else {
            throw GOGError.failed("Couldn't find how to start \(game.title). Try reinstalling it.")
        }
        func local(_ windowsPath: String) -> URL {
            windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).reduce(folder) { $0.appendingPathComponent(String($1)) }
        }
        let exe = local(task.path)
        let workDir = task.workingDirectory.map(local) ?? exe.deletingLastPathComponent()
        return try runner.run(engine: engine, bottle: bottle, executable: exe.path,
                              arguments: task.arguments + profile.extraArguments,
                              workingDirectory: workDir, profile: profile, logID: game.id, onExit: onExit)
    }

    // MARK: Helpers

    /// The folder holding `goggame-<id>.info`; a newly created folder wins when several match.
    func findInstall(id: String, preferring before: Set<String>) -> URL? {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: gamesFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("goggame-\(id).info").path) }
        return dirs.first { !before.contains($0.lastPathComponent) } ?? dirs.first
    }

    func loadInstalled() -> GOGInstalled {
        (try? JSONDecoder().decode(GOGInstalled.self, from: Data(contentsOf: installedFile))) ?? GOGInstalled()
    }

    func saveInstalled(_ value: GOGInstalled) throws {
        try FileManager.default.createDirectory(at: paths.gogConfig, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: installedFile, options: .atomic)
    }

    static func folderSize(_ url: URL) -> Int64? {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Runs gogdl and returns stdout only (it logs to stderr, and its JSON must stay clean).
    private func stdout(_ args: [String]) async throws -> Data {
        guard isHelperInstalled else { throw GOGError.helperMissing }
        let process = Process()
        process.executableURL = gogdl
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
