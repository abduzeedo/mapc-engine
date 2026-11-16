import Foundation

/// Ubisoft games bought on Epic (`Game.requiredLauncher == .ubisoft`) start Ubisoft Connect themselves and quit when
/// it isn't installed. The Epic launcher installs it as the game's prerequisite after the download; legendary runs
/// prerequisites only on Windows ("Automatic installation not available"), so on a Mac the game just closed with no
/// window and no error (2026-11-16 report, Assassin's Creed Origins). MaPC installs it into the Epic environment,
/// where the game looks for it, from Ubisoft's official installer: the same one the Ubisoft Connect store uses.
extension EpicProvider {
    /// Where Ubisoft's installer puts Ubisoft Connect inside the Epic environment.
    public var ubisoftConnectExecutable: URL {
        bottle.driveC.appendingPathComponent("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe")
    }

    public var hasUbisoftConnect: Bool { FileManager.default.fileExists(atPath: ubisoftConnectExecutable.path) }

    /// Whether Play has to install Ubisoft Connect before it starts this game.
    public func needsUbisoftConnectInstall(for game: Game) -> Bool {
        game.store == .epic && game.requiredLauncher == .ubisoft && !hasUbisoftConnect
    }

    /// Downloads Ubisoft's installer and runs it silently in the Epic environment, which must already exist
    /// (`BottleManager.prepareForPlay`). Does nothing when Ubisoft Connect is there. A failure is written to
    /// `Logs/epic-setup/` with the installer's exit status and the end of its output.
    public func installUbisoftConnect(engine: Engine) async throws {
        guard !hasUbisoftConnect else { return }
        let manager = BottleManager(paths: paths)
        func failed(_ step: String, _ error: Error, output: String = "") -> Error {
            manager.recordSetupFailure(.epic, engine: engine, detail: "Ubisoft Connect, \(step): \(error.localizedDescription)",
                                       output: output)
            return error
        }
        let ubisoft = LauncherStore(kind: .ubisoft, paths: paths)
        let tmp: URL
        do {
            let (file, response) = try await URLSession.shared.download(from: ubisoft.installerURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw WineRunnerError.launchFailed("couldn't download the Ubisoft Connect installer (HTTP \(status))")
            }
            tmp = file
        } catch { throw failed("downloading the installer", error) }
        let installer = paths.home.appendingPathComponent("epic-ubisoft-setup.exe")
        try? FileManager.default.removeItem(at: installer)
        try FileManager.default.moveItem(at: tmp, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        let result: ProcessResult
        do { result = try await ProcessRunner.run(engine.wine, [installer.path] + ubisoft.installerArguments, environment: env) }
        catch { throw failed("starting the installer", error) }
        guard hasUbisoftConnect else {
            let error = WineRunnerError.launchFailed("Ubisoft Connect, which this game needs, didn't install")
            throw failed("installer exited with status \(result.status) and UbisoftConnect.exe is missing", error,
                         output: result.output)
        }
    }
}
