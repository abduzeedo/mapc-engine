import Foundation

public enum WineRunnerError: Error, LocalizedError {
    case noEngine
    case bottleMissing(BottleKind)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noEngine: "The game engine isn't installed yet."
        case .bottleMissing(let k): "The \(k.rawValue) environment hasn't been set up yet."
        case .launchFailed(let m): "Couldn't start the program: \(m)"
        }
    }
}

/// A process started by `WineRunner`. Lifetime is tracked through the termination handler (no polling).
public final class RunningProcess: @unchecked Sendable {
    private let process: Process
    public let logURL: URL
    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    init(process: Process, logURL: URL) {
        self.process = process
        self.logURL = logURL
    }

    public func terminate() { if process.isRunning { process.terminate() } }
}

/// Every Windows program Macade starts goes through here (plan §4.3).
public struct WineRunner: Sendable {
    public let paths: Paths
    public let logs: LogStore

    public init(paths: Paths) {
        self.paths = paths
        self.logs = LogStore(paths: paths)
    }

    // MARK: Environment (pure, unit-tested)

    /// The variables inherited from the app. Everything else is dropped so the host
    /// environment can't leak into Wine (we saw tool variables show up in Steam's command line).
    static let inheritedKeys = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "SHELL"]

    /// `profile.backend` should already be resolved for the game (`.auto` falls back to DXVK here).
    public static func environment(
        bottle: Bottle,
        profile: LaunchProfile,
        engine: Engine? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment,
        extraOverrides: [String] = []
    ) -> [String: String] {
        var env = base.filter { inheritedKeys.contains($0.key) }
        let backend = profile.backend.resolved()

        env["WINEPREFIX"] = bottle.url.path
        env["WINEDEBUG"] = profile.verboseLogs ? "err+all,warn+module" : "-all"
        env["WINEESYNC"] = "1"
        env["WINEMSYNC"] = "1"
        env["ROSETTA_ADVERTISE_AVX"] = "1"

        // No Mono/Gecko prompts, no Launchpad stubs. A bottle that has Wine Mono keeps it enabled.
        // DXVK/DXMT overrides only on an engine that ships them. On a D3DMetal engine they would do nothing but
        // let a game pick up the native Direct3D DLLs that `WineD3DFallback` puts in System32 for one launcher.
        let shipsBackend = engine.map { $0.info.backends.contains(backend.rawValue) } ?? true
        let backendOverrides = shipsBackend ? backend.overrides : []
        let overrides = [bottle.hasMono ? "mshtml=" : "mscoree,mshtml=", "winemenubuilder.exe=d"] + backendOverrides + extraOverrides
        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")

        for (k, v) in backend.environment { env[k] = v }
        if backend == .d3dMetal, let d3dshared = engine?.d3dMetalLibrary {
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dshared.path
            env["CX_ACTIVE_GRAPHICS_BACKEND"] = "d3dmetal"   // CrossOver then reports GPU scheduling to DX12 games
        }
        if backend == .d3dMetal {
            env["D3DM_SUPPORT_DXR"] = profile.rayTracing ? "1" : "0"
            if profile.metalFX { env["D3DM_ENABLE_METALFX"] = "1" }
        }
        if profile.performanceHUD { env["MTL_HUD_ENABLED"] = "1" }
        for (k, v) in profile.extraEnvironment { env[k] = v }   // user settings win
        return env
    }

    // MARK: Launching

    /// Starts `executable` (a Windows path or program name) in the bottle. Returns immediately.
    @discardableResult
    public func run(
        engine: Engine,
        bottle: Bottle,
        executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        profile: LaunchProfile = LaunchProfile(),
        extraOverrides: [String] = [],
        logID: String,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> RunningProcess {
        try launch(program: engine.wine, arguments: [executable] + arguments, engine: engine, bottle: bottle,
                   workingDirectory: workingDirectory, profile: profile, extraOverrides: extraOverrides,
                   logID: logID, onExit: onExit)
    }

    /// Starts any native program (e.g. legendary) with Wine's environment for `bottle`.
    @discardableResult
    public func launch(
        program: URL,
        arguments: [String],
        engine: Engine,
        bottle: Bottle,
        workingDirectory: URL? = nil,
        profile: LaunchProfile = LaunchProfile(),
        extraOverrides: [String] = [],
        extraEnvironment: [String: String] = [:],
        logID: String,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> RunningProcess {
        guard bottle.exists else { throw WineRunnerError.bottleMissing(bottle.kind) }
        try paths.createDirectories()
        let logURL = try logs.newLog(for: logID)
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            throw WineRunnerError.launchFailed("can't open log file")
        }

        let backend = profile.backend.resolved()
        do { try NativeBackendDLLs.prepare(backend, engine: engine, bottle: bottle) }
        catch {
            try? handle.close()
            throw WineRunnerError.launchFailed("couldn't set up \(backend.displayName): \(error.localizedDescription)")
        }

        let context = "[MaPC] Launch \(ISO8601DateFormatter().string(from: Date())) engine=\(engine.version) wine=\(engine.info.wineVersion) environment=\(bottle.kind.rawValue) backend=\(backend.rawValue)\n"
        try handle.write(contentsOf: Data(context.utf8))
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var env = Self.environment(bottle: bottle, profile: profile, engine: engine, extraOverrides: extraOverrides)
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { p in
            let event = "\n[MaPC] Exit \(ISO8601DateFormatter().string(from: Date())) pid=\(p.processIdentifier) status=\(p.terminationStatus) reason=\(p.terminationReason == .uncaughtSignal ? "signal" : "exit")\n"
            try? handle.write(contentsOf: Data(event.utf8))
            try? handle.close()
            onExit?(p.terminationStatus)
        }
        do { try process.run() }
        catch {
            try? handle.close()
            throw WineRunnerError.launchFailed(error.localizedDescription)
        }
        return RunningProcess(process: process, logURL: logURL)
    }

    /// `wineserver -k` for the bottle: stops everything running in it.
    public func killAll(engine: Engine, bottle: Bottle) async {
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        _ = try? await ProcessRunner.run(engine.wineserver, ["-k"], environment: env)
    }

    /// True if a wineserver for this bottle is alive (used to re-attach after the app restarts).
    public func isBottleActive(engine: Engine, bottle: Bottle) async -> Bool {
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        let r = try? await ProcessRunner.run(engine.wineserver, ["-k0"], environment: env)
        return r?.succeeded == true
    }
}

public extension WineRunner {
    /// Writes Wine's Mac driver options (bottle-wide registry values, e.g. `RetinaMode`,
    /// `LeftCommandIsCtrl`). They take effect the next time Wine starts.
    func applyMacDriver(_ values: [String: Bool], engine: Engine, bottle: Bottle) async {
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        for (name, enabled) in values.sorted(by: { $0.key < $1.key }) {
            _ = try? await ProcessRunner.run(
                engine.wine, ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", name, "/d", enabled ? "y" : "n", "/f"],
                environment: env)
        }
    }
}
