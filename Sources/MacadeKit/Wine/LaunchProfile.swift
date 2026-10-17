import Foundation

/// Per-game launch settings. Pure value type: it only describes, `WineRunner` acts.
public struct LaunchProfile: Codable, Hashable, Sendable {
    public var backend: GraphicsBackend = .auto
    public var performanceHUD = false
    public var retina = true
    public var verboseLogs = false
    /// D3DMetal: upscale with MetalFX where a game offers NVIDIA DLSS.
    public var metalFX = false
    /// D3DMetal: DirectX ray tracing (DXR) on Apple GPUs that support it.
    public var rayTracing = true
    /// The Command keys act as Control, so Windows shortcuts (Ctrl+C, Ctrl+S…) work with ⌘.
    public var commandAsControl = false
    public var extraEnvironment: [String: String] = [:]
    public var extraArguments: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case backend, performanceHUD, retina, verboseLogs, metalFX, rayTracing, commandAsControl, extraEnvironment, extraArguments
    }

    /// Missing keys keep their defaults, so profiles saved by older versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LaunchProfile()
        backend = try c.decodeIfPresent(GraphicsBackend.self, forKey: .backend) ?? d.backend
        performanceHUD = try c.decodeIfPresent(Bool.self, forKey: .performanceHUD) ?? d.performanceHUD
        retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? d.retina
        verboseLogs = try c.decodeIfPresent(Bool.self, forKey: .verboseLogs) ?? d.verboseLogs
        metalFX = try c.decodeIfPresent(Bool.self, forKey: .metalFX) ?? d.metalFX
        rayTracing = try c.decodeIfPresent(Bool.self, forKey: .rayTracing) ?? d.rayTracing
        commandAsControl = try c.decodeIfPresent(Bool.self, forKey: .commandAsControl) ?? d.commandAsControl
        extraEnvironment = try c.decodeIfPresent([String: String].self, forKey: .extraEnvironment) ?? d.extraEnvironment
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? d.extraArguments
    }
}

public extension LaunchProfile {
    /// Parses `KEY=value` lines (blank lines and `#` comments ignored; bad lines skipped).
    static func parseEnvironment(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            out[key] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    static func formatEnvironment(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    /// Splits a launch-arguments field, honoring simple double quotes.
    static func parseArguments(_ text: String) -> [String] {
        var args: [String] = [], current = "", inQuotes = false, started = false
        for c in text {
            if c == "\"" { inQuotes.toggle(); started = true }
            else if c.isWhitespace && !inQuotes { if started { args.append(current); current = ""; started = false } }
            else { current.append(c); started = true }
        }
        if started { args.append(current) }
        return args
    }
}
