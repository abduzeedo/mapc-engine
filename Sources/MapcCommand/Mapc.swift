import Foundation
import MacadeKit

/// Runs a parsed `Command`. Reads MaPC's settings but never writes them.
public struct Mapc {
    public let paths: Paths
    public init(paths: Paths = Paths()) { self.paths = paths }

    /// Returns the process exit status.
    public static func main(_ args: [String]) async -> Int32 {
        do {
            return try await Mapc().execute(try Parser.parse(args))
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("mapc: \(error)\n\nRun `mapc help` for usage.\n".utf8))
            return 64
        } catch {
            FileHandle.standardError.write(Data("mapc: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    func execute(_ command: Command) async throws -> Int32 {
        switch command {
        case .help:
            print(Parser.usage)
        case .engines:
            let engines = EngineLocator(paths: paths).installed()
            if engines.isEmpty { print("No engines in \(paths.engines.path)") }
            for e in engines {
                print("\(e.version)\tWine \(e.info.wineVersion)\tbackends: \(e.info.backends.joined(separator: ", "))")
            }
        case .probe(let folder):
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
                throw UsageError("not a folder: \(folder)")
            }
            let probe = GraphicsProbe.scan(URL(fileURLWithPath: folder, isDirectory: true))
            print("DirectX 12:        \(probe.usesDirectX12 ? "yes" : "no")")
            print("64-bit executable: \(probe.has64BitExecutable ? "yes" : "no")")
            print("Automatic picks:   \(GraphicsBackend.auto.resolved(for: probe, d3dMetalAvailable: d3dMetalInstalled).displayName)")
        case .env(let options):
            let (engine, profile) = try resolve(options)
            let env = WineRunner.environment(bottle: Bottle(kind: options.bottle, paths: paths), profile: profile, engine: engine)
            print("# engine \(engine.version), backend \(profile.backend.displayName)")
            print(LaunchProfile.formatEnvironment(env))
        case .run(let options, let program, let arguments):
            return try await run(options, program: program, arguments: arguments)
        }
        return 0
    }

    var d3dMetalInstalled: Bool { EngineLocator(paths: paths).installed().contains { $0.supports(.d3dMetal) } }

    /// The engine and profile for these options, the way the app resolves them before Play.
    func resolve(_ options: Options) throws -> (Engine, LaunchProfile) {
        var profile = options.profile
        let probe = options.gameFolder.map { GraphicsProbe.scan(URL(fileURLWithPath: $0, isDirectory: true)) }
        profile.backend = profile.backend.resolved(for: probe, d3dMetalAvailable: d3dMetalInstalled)
        let settings = JSONStore<AppSettings>(url: paths.settingsFile).load(default: AppSettings())
        let locator = EngineLocator(paths: paths)
        let engine = try EngineChoice.pick(
            requested: options.engine, recorded: settings.bottleEngines?[options.bottle.rawValue],
            installed: locator.installed()) {
            locator.engine(for: profile.backend.resolved(), activeVersion: settings.activeEngineVersion)
        }
        if profile.backend == .d3dMetal && !engine.supports(.d3dMetal) {
            throw UsageError("engine \(engine.version) can't run D3DMetal; pick another with --engine or --backend")
        }
        return (engine, profile)
    }

    func run(_ options: Options, program: String, arguments: [String]) async throws -> Int32 {
        let (engine, profile) = try resolve(options)
        let bottle = Bottle(kind: options.bottle, paths: paths)
        guard bottle.exists else { throw WineRunnerError.bottleMissing(options.bottle) }
        let runner = WineRunner(paths: paths)
        // Same rule as the app: another engine can't join a running bottle's wineserver.
        let settings = JSONStore<AppSettings>(url: paths.settingsFile).load(default: AppSettings())
        let recorded = settings.bottleEngines?[options.bottle.rawValue]
        if let recorded, recorded != engine.version, await runner.isBottleActive(engine: engine, bottle: bottle) {
            throw UsageError("the \(options.bottle.rawValue) environment is running on engine \(recorded). Quit it in MaPC first.")
        }
        if let recorded, recorded != engine.version {
            FileHandle.standardError.write(Data("mapc: note: MaPC last ran this environment on engine \(recorded).\n".utf8))
        }

        print("engine \(engine.version), backend \(profile.backend.displayName), environment \(options.bottle.rawValue)")
        let finished = AsyncStream<Int32>.makeStream()
        let process = try runner.run(engine: engine, bottle: bottle, executable: program,
                                     arguments: profile.extraArguments + arguments, profile: profile,
                                     logID: "mapc") { status in
            finished.continuation.yield(status)
            finished.continuation.finish()
        }
        print("log: \(process.logURL.path)")
        var status: Int32 = 0
        for await s in finished.stream { status = s }
        print("exited with status \(status)")
        return status
    }
}
