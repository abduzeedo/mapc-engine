import Foundation

/// Wine's Mac driver options (`HKCU\Software\Wine\Mac Driver`): Retina mode and Command as Control. They are
/// bottle-wide, so each launch makes the registry match the game's profile. The registry itself is the reference,
/// not a record of what MaPC last wrote: anything else that writes there (another program, `regedit`, a write that
/// failed) would otherwise go unnoticed, and every launch would keep the wrong setting.
public enum MacDriver {
    public static let key = #"HKCU\Software\Wine\Mac Driver"#
    /// The key as `user.reg` names it: relative to HKCU, backslashes escaped.
    static let userRegSection = #"[Software\\Wine\\Mac Driver]"#

    /// What the bottle needs for `profile`, by registry value name.
    public static func values(for profile: LaunchProfile) -> [String: Bool] {
        ["RetinaMode": profile.retina,
         "LeftCommandIsCtrl": profile.commandAsControl, "RightCommandIsCtrl": profile.commandAsControl]
    }

    /// How the Mac driver reads an option (`IS_OPTION_TRUE`): y, t or 1 is on, n, f or 0 is off. Anything else,
    /// including a missing value, is nil: the engine's default applies, so MaPC writes it.
    public static func flag(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespaces).first {
        case "y", "Y", "t", "T", "1": true
        case "n", "N", "f", "F", "0": false
        default: nil
        }
    }

    /// The values to write: those the registry doesn't already hold. When the registry couldn't be read (nil),
    /// all of them, since writing a value it already has changes nothing.
    public static func changes(wanted: [String: Bool], registry: [String: String]?) -> [String: Bool] {
        guard let registry else { return wanted }
        let current = Dictionary(registry.map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
        return wanted.filter { flag(current[$0.key.lowercased()]) != $0.value }
    }

    // MARK: Reading

    /// The key's string values in a bottle's `user.reg` (what the next wineserver loads). Empty when the key is
    /// missing. Values of other types (dword, hex) are left out, so they count as unset.
    public static func parse(userReg text: String) -> [String: String] {
        guard let header = sectionStart(in: text) else { return [:] }
        var values: [String: String] = [:]
        // isNewline: "\r\n" is one Character, so splitting on "\n" alone would join such lines.
        for line in text[header...].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).dropFirst() {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("[") { break }   // the next key
            guard let (name, rest) = quoted(line[...]), rest.hasPrefix("="),
                  let (value, _) = quoted(rest.dropFirst()) else { continue }
            values[name] = value
        }
        return values
    }

    /// `reg query` output: `    RetinaMode    REG_SZ    y`. Only REG_SZ values, like `parse(userReg:)`.
    public static func parse(regQuery output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.components(separatedBy: "    ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard fields.count >= 2, fields[1] == "REG_SZ" else { continue }
            values[fields[0]] = fields.dropFirst(2).joined(separator: "    ")
        }
        return values
    }

    /// The header line `[Software\\Wine\\Mac Driver] <time>`, at the start of a line.
    private static func sectionStart(in text: String) -> String.Index? {
        var from = text.startIndex
        while let r = text.range(of: userRegSection, options: .caseInsensitive, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex || text[text.index(before: r.lowerBound)].isNewline { return r.lowerBound }
            from = r.upperBound
        }
        return nil
    }

    /// A `"..."` string at the start of `s` (backslash escapes undone), and what follows it.
    private static func quoted(_ s: Substring) -> (String, Substring)? {
        guard s.first == "\"" else { return nil }
        var out = "", i = s.index(after: s.startIndex)
        while i < s.endIndex {
            let c = s[i]
            if c == "\"" { return (out, s[s.index(after: i)...]) }
            if c == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i) }
            out.append(s[i])
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: Syncing

    /// What a sync did. Values in `failed` were not written; the next launch reads the registry and tries again.
    public struct SyncResult: Equatable, Sendable {
        /// What the registry held before, or nil when it couldn't be read.
        public var before: [String: String]?
        public var written: [String: Bool] = [:]
        public var failed: [String: Bool] = [:]
        public var succeeded: Bool { failed.isEmpty }
    }

    /// Reads the registry, writes what differs from `wanted`, and records each write's outcome.
    static func sync(_ wanted: [String: Bool],
                     read: () async -> [String: String]?,
                     write: (String, Bool) async -> Bool) async -> SyncResult {
        let before = await read()
        var result = SyncResult(before: before)
        for (name, enabled) in changes(wanted: wanted, registry: before).sorted(by: { $0.key < $1.key }) {
            if await write(name, enabled) { result.written[name] = enabled } else { result.failed[name] = enabled }
        }
        return result
    }
}

public extension WineRunner {
    /// The bottle's Mac driver values now, or nil when they can't be read. A running wineserver holds the registry
    /// in memory and saves it only every few seconds, so it's asked (`reg query`). Without one, `user.reg` is what
    /// the next wineserver loads, and reading the file is instant and starts nothing.
    func macDriverRegistry(engine: Engine, bottle: Bottle) async -> [String: String]? {
        if await isBottleActive(engine: engine, bottle: bottle) {
            let env = Self.environment(bottle: bottle, profile: LaunchProfile())
            // Status 1 is also what a client the wineserver refused (other sync options) returns: unknown, not empty.
            guard let r = try? await ProcessRunner.run(engine.wine, ["reg", "query", MacDriver.key], environment: env),
                  r.succeeded else { return nil }
            return MacDriver.parse(regQuery: r.output)
        }
        guard let data = try? Data(contentsOf: bottle.url.appendingPathComponent("user.reg"), options: .mappedIfSafe) else { return nil }
        return MacDriver.parse(userReg: String(decoding: data, as: UTF8.self))
    }

    /// Makes the bottle's Mac driver options match `values`: reads the registry and writes only what differs,
    /// checking each write. They take effect for programs started afterwards.
    @discardableResult
    func syncMacDriver(_ values: [String: Bool], engine: Engine, bottle: Bottle) async -> MacDriver.SyncResult {
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        return await MacDriver.sync(values, read: { await macDriverRegistry(engine: engine, bottle: bottle) }) { name, enabled in
            let r = try? await ProcessRunner.run(
                engine.wine, ["reg", "add", MacDriver.key, "/v", name, "/d", enabled ? "y" : "n", "/f"], environment: env)
            return r?.succeeded == true
        }
    }
}
