import Foundation

/// Epic cloud saves. The Epic launcher syncs a game's saves around every session; legendary only does it when
/// asked (`sync-saves`), and only knows where the saves are once it's given `--save-path`. So MaPC resolves the
/// game's `CloudSaveFolder` in the Epic bottle itself and syncs before and after each launch.
public enum EpicCloudSaves {
    public enum Moment: Sendable { case beforePlay, afterPlay }

    public enum Outcome: Equatable, Sendable {
        /// Epic doesn't keep this game's saves, or the folder can't be worked out.
        case unsupported
        case synced
        case failed(String)
    }

    /// `CloudSaveFolder` from legendary's cached game metadata (`metadata/<app>.json`).
    static func cloudSaveFolder(metadataJSON: Data) -> String? {
        struct Meta: Decodable {
            struct Inner: Decodable {
                struct Attribute: Decodable { let value: String? }
                let customAttributes: [String: Attribute]?
            }
            let metadata: Inner?
        }
        let value = (try? JSONDecoder().decode(Meta.self, from: metadataJSON))?.metadata?.customAttributes?["CloudSaveFolder"]?.value
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    /// The signed-in account's id, legendary's `{EpicID}` (`user.json`).
    static func accountID(userJSON: Data) -> String? {
        struct User: Decodable { let account_id: String? }
        return (try? JSONDecoder().decode(User.self, from: userJSON))?.account_id
    }

    /// Whether legendary already has a save folder for the game (`installed.json`). Nil when it isn't installed.
    static func hasSavePath(installedJSON: Data, appName: String) -> Bool? {
        struct Entry: Decodable { let save_path: String? }
        guard let entry = (try? JSONDecoder().decode([String: Entry].self, from: installedJSON))?[appName] else { return nil }
        return !(entry.save_path ?? "").isEmpty
    }

    /// Resolves a `CloudSaveFolder` such as `{AppData}/Remedy/AlanWake2/{EpicID}/` in the bottle, the way
    /// legendary does on Windows (`{AppData}` is AppData\Local). Nil for an unknown variable, a path that doesn't
    /// start at one of them, or one that would leave its root.
    public static func resolve(_ template: String, roots: SaveRoots, epicID: String) -> URL? {
        var parts = template.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let first = parts.first, first.hasPrefix("{"), first.hasSuffix("}") else { return nil }
        let base: URL?
        switch first.lowercased() {
        case "{appdata}": base = roots.base(.local)
        case "{userdir}": base = roots.base(.documents)
        case "{userprofile}": base = roots.profile
        case "{usersavedgames}": base = roots.base(.savedGames)
        case "{installdir}": base = roots.install
        default: base = nil
        }
        guard var url = base else { return nil }
        parts.removeFirst()
        for part in parts {
            let name = part.replacingOccurrences(of: "{epicid}", with: epicID, options: .caseInsensitive)
            guard !name.contains("{"), name != ".", name != "..", !name.contains("\0") else { return nil }
            url.appendPathComponent(name, isDirectory: true)
        }
        return url
    }
}

extension EpicProvider {
    /// How long a sync may take before the launch (or the exit) goes on without it.
    static let saveSyncTimeout: Duration = .seconds(120)

    /// Syncs the game's Epic cloud saves. Before playing it only downloads a newer cloud save; after playing it
    /// only uploads a newer local one, so one session's sync can never overwrite progress it didn't make.
    ///
    /// The first time (legendary has no save folder for the game yet) the cloud save wins: a game started in
    /// MaPC without it writes a near-empty first-launch save that is newer than real progress made elsewhere.
    /// The local folder is copied to `<bottle>/save-sync-backups/` first, and nothing is uploaded until that
    /// download has happened.
    public func syncSaves(_ game: Game, _ moment: EpicCloudSaves.Moment, now: Date = Date()) async -> EpicCloudSaves.Outcome {
        guard isLegendaryInstalled, isSignedIn else { return .unsupported }
        let config = paths.legendaryConfig
        guard let meta = try? Data(contentsOf: config.appendingPathComponent("metadata/\(game.storeID).json")),
              let template = EpicCloudSaves.cloudSaveFolder(metadataJSON: meta),
              let user = try? Data(contentsOf: config.appendingPathComponent("user.json")),
              let epicID = EpicCloudSaves.accountID(userJSON: user),
              let folder = EpicCloudSaves.resolve(template, roots: SaveRoots(bottle: bottle, installPath: game.installPath), epicID: epicID)
        else { return .unsupported }
        let installed = try? Data(contentsOf: config.appendingPathComponent("installed.json"))
        let firstSync = installed.flatMap { EpicCloudSaves.hasSavePath(installedJSON: $0, appName: game.storeID) } == false

        var args = ["sync-saves", game.storeID, "--save-path", folder.path, "-y"]
        switch moment {
        case .beforePlay:
            args.append("--skip-upload")
            if firstSync {
                do { try backUp(folder, appName: game.storeID, now: now) }
                catch { return .failed("Couldn't back up the local saves before the first sync.") }
                args.append("--force-download")
            }
        case .afterPlay:
            // Without a download first, a newer local save may only be the first-launch one: don't upload it.
            guard !firstSync else { return .failed("Saves weren't synced before playing, so they weren't uploaded.") }
            args.append("--skip-download")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let result = try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
                group.addTask { try await ProcessRunner.run(legendary, args, environment: environment) }
                group.addTask { try await Task.sleep(for: Self.saveSyncTimeout); return nil }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let result else { return .failed("Syncing saves with Epic took too long.") }
            return result.succeeded ? .synced : .failed("Couldn't sync saves with Epic.")
        } catch {
            return .failed("Couldn't sync saves with Epic.")
        }
    }

    /// Copies the save folder aside, if it has anything in it.
    private func backUp(_ folder: URL, appName: String, now: Date) throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: folder.path), contents.contains(where: { $0 != ".DS_Store" }) else { return }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd-HHmmss"
        let target = bottle.url.appendingPathComponent("save-sync-backups/\(SaveBackupStore.safeID(appName))/\(format.string(from: now))", isDirectory: true)
        try SaveBackupStore.copyTree(from: folder, to: target)
    }
}
