import Foundation
import MacadeKit

/// What `mapc` was asked to do. Parsing is pure so it can be tested without running anything.
public enum Command: Equatable {
    case help
    case engines
    case probe(folder: String)
    case diagnose(log: String)
    case env(Options)
    case run(Options, program: String, arguments: [String])
}

/// Settings shared by `env` and `run`.
public struct Options: Equatable {
    public var bottle: BottleKind = .steam
    public var backend: GraphicsBackend = .auto
    /// An engine version from `mapc engines`. `nil`: the one the environment last ran with.
    public var engine: String?
    public var verbose = false
    public var hud = false
    /// `KEY=value` pairs, applied last like the app's per-game environment variables.
    public var environment: [String: String] = [:]
    /// Game folder to look at when the backend is Automatic (DirectX 12 games then get D3DMetal).
    public var gameFolder: String?

    public init() {}

    public var profile: LaunchProfile {
        var p = LaunchProfile()
        p.backend = backend
        p.verboseLogs = verbose
        p.performanceHUD = hud
        p.extraEnvironment = environment
        return p
    }
}

public struct UsageError: Error, Equatable, CustomStringConvertible {
    public let description: String
    init(_ message: String) { description = message }
}

public enum Parser {
    public static let usage = """
    mapc: runs Windows programs the way the MaPC app does, for testing changes to MacadeKit.

    USAGE
      mapc engines                          installed engines
      mapc probe <game folder>              what the game's files say about its graphics
      mapc diagnose <log file>              known problems in a launch log
      mapc env [options]                    the environment Wine would get
      mapc run [options] <program> [args]   run a program (Windows path, or a Mac path inside the environment)

    OPTIONS
      --bottle steam|epic|gog|ubisoft|ea    which environment (default: steam)
      --backend auto|dxvk|d3dMetal|dxmt|wined3d   graphics (default: auto)
      --engine <version>                    engine to use (default: the one the environment last ran with)
      --game <folder>                       with --backend auto: pick the backend for this game
      --env KEY=value                       extra environment variable (repeatable)
      --verbose                             Wine's error and module logging
      --hud                                 Metal performance HUD

    MaPC's data folder is used; set MACADE_HOME to use another one.
    """

    public static func parse(_ args: [String]) throws -> Command {
        guard let verb = args.first else { return .help }
        var rest = Array(args.dropFirst())
        switch verb {
        case "help", "-h", "--help": return .help
        case "engines":
            guard rest.isEmpty else { throw UsageError("engines takes no arguments") }
            return .engines
        case "probe":
            guard rest.count == 1 else { throw UsageError("probe needs one game folder") }
            return .probe(folder: rest[0])
        case "diagnose":
            guard rest.count == 1 else { throw UsageError("diagnose needs one log file") }
            return .diagnose(log: rest[0])
        case "env":
            let options = try parseOptions(&rest)
            guard rest.isEmpty else { throw UsageError("unexpected argument: \(rest[0])") }
            return .env(options)
        case "run":
            let options = try parseOptions(&rest)
            guard let program = rest.first else { throw UsageError("run needs a program") }
            return .run(options, program: program, arguments: Array(rest.dropFirst()))
        default:
            throw UsageError("unknown command: \(verb)")
        }
    }

    /// Reads options from the front of `args` and stops at the first argument that isn't one
    /// (so a program's own `--flags` after its name are left alone).
    static func parseOptions(_ args: inout [String]) throws -> Options {
        var o = Options()
        func value(_ flag: String) throws -> String {
            guard args.count >= 2 else { throw UsageError("\(flag) needs a value") }
            let v = args[1]; args.removeFirst(2); return v
        }
        while let flag = args.first, flag.hasPrefix("--") {
            switch flag {
            case "--bottle":
                let v = try value(flag)
                guard let kind = BottleKind(rawValue: v) else { throw UsageError("unknown bottle: \(v)") }
                o.bottle = kind
            case "--backend":
                let v = try value(flag)
                guard let b = GraphicsBackend.allCases.first(where: { $0.rawValue.lowercased() == v.lowercased() }) else {
                    throw UsageError("unknown backend: \(v)")
                }
                o.backend = b
            case "--engine": o.engine = try value(flag)
            case "--game": o.gameFolder = try value(flag)
            case "--env":
                let v = try value(flag)
                let parsed = LaunchProfile.parseEnvironment(v)
                guard parsed.count == 1 else { throw UsageError("--env wants KEY=value, got: \(v)") }
                o.environment.merge(parsed) { _, new in new }
            case "--verbose": o.verbose = true; args.removeFirst()
            case "--hud": o.hud = true; args.removeFirst()
            case "--": args.removeFirst(); return o
            default: throw UsageError("unknown option: \(flag)")
            }
        }
        return o
    }
}

public enum EngineChoice {
    /// The engine for a bottle, following the app's rule: a bottle's wineserver belongs to the engine that
    /// started it, so by default use that one (`recorded`, the app's `bottleEngines` entry). Otherwise the app's
    /// own choice for the backend (`EngineLocator.engine(for:activeVersion:)`), passed in as `fallback`.
    public static func pick(requested: String?, recorded: String?, installed: [Engine],
                            fallback: () -> Engine?) throws -> Engine {
        if let requested {
            guard let e = installed.first(where: { $0.version == requested }) else {
                throw UsageError("engine \(requested) isn't installed (see mapc engines)")
            }
            return e
        }
        if let recorded, let e = installed.first(where: { $0.version == recorded }) { return e }
        guard let e = fallback() else { throw UsageError("no engine installed. Open MaPC once to download one.") }
        return e
    }
}
