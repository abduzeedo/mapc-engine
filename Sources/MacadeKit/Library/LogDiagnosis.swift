import Foundation

/// Reads a game's launch log and names known problems in plain language, each with one thing to do.
/// Pure text matching on patterns seen in real reports; nothing is sent anywhere. The app may then ask an
/// on-device model to explain the findings, but the findings themselves always come from here.
public struct LogDiagnosis: Equatable, Sendable {
    /// What the user can do about a finding. The app turns these into buttons.
    public enum Action: Equatable, Sendable {
        case useBackend(GraphicsBackend)
        case installExtendedEngine
        case setUpDirectX12
        /// Replace engine `from`, which the engine list dropped, with `to` (see `EngineManifest.updates`).
        case updateEngine(from: String, to: String)
        /// The store released an update the game needs before it starts (Epic, through legendary).
        case updateGame
        /// The game's program is .NET and the environment has no runtime: install Wine Mono (`WineMono`) into it.
        case installDotNet
        case reportProblem
        case none
    }

    public struct Finding: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let action: Action
        /// The log line that matched, so the user (and the model) can see the evidence.
        public let evidence: String?
    }

    /// From the `[MaPC] Launch` / `[MaPC] Exit` lines of the last launch in the log.
    public struct Launch: Equatable, Sendable {
        public var engine: String?
        public var backend: String?
        public var environment: String?
        public var started: Date?
        public var ended: Date?
        public var status: Int32?
        public var bySignal = false
        public var seconds: TimeInterval? { started.flatMap { s in ended.map { $0.timeIntervalSince(s) } } }
    }

    public let launch: Launch?
    public let findings: [Finding]

    /// Log lines worth showing (errors and crashes), deduplicated and capped, for the user or a model.
    public let excerpt: [String]

    // MARK: Reading

    /// The start (the launch line) and the end (how it ended) of a log; game logs can be tens of megabytes of
    /// Vulkan feature lists in between.
    public static func read(_ url: URL, headBytes: Int = 64 << 10, tailBytes: Int = 2 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard size > UInt64(headBytes + tailBytes) else {
            return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
        }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        try? handle.seek(toOffset: size - UInt64(tailBytes))
        let tail = (try? handle.readToEnd()) ?? Data()
        return String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }

    /// `engineUpdates`: installed engines the engine list replaced (`EngineManifest.updates`), so a crash at start on
    /// one of them points to its replacement instead of a report. `title`: the game's name, for findings that depend
    /// on the game (the log often doesn't name it).
    public init(log: String, probe: GraphicsProbe? = nil, dxmtAvailable: Bool = false, d3dMetalAvailable: Bool = false,
                engineUpdates: [EngineManifest.Update] = [], title: String? = nil) {
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        let launch = Self.lastLaunch(in: lines)
        self.launch = launch
        var found: [Finding] = []
        func add(_ id: String, _ title: String, _ detail: String, _ action: Action, _ evidence: String?) {
            guard !found.contains(where: { $0.id == id }) else { return }
            found.append(Finding(id: id, title: title, detail: detail, action: action, evidence: evidence.map(Self.trim)))
        }
        func line(_ needle: String) -> String? { lines.last { $0.localizedCaseInsensitiveContains(needle) } }

        if let e = line("Only external memory handle type VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER") {
            add("vulkan-32bit", "32-bit DirectX 11 can't use Vulkan on a Mac",
                "The game is 32-bit and asked DXVK (Vulkan) for a DirectX 11 device, which MoltenVK can't create for 32-bit programs. DXMT can.",
                dxmtAvailable ? .useBackend(.dxmt) : .installExtendedEngine, e)
        }
        if let e = line("None of the requested D3D feature levels is supported") {
            add("wined3d-level", "WineD3D can't run this game on a Mac",
                "Wine's own Direct3D runs on OpenGL, which on macOS stops below what the game asks for.",
                probe?.uses32BitDirect3D11 == true ? (dxmtAvailable ? .useBackend(.dxmt) : .installExtendedEngine) : .useBackend(.dxvk), e)
        }
        if let e = line("Support for DirectX 12 is required") ?? line("D3D12CreateDevice failed") {
            add("needs-dx12", "The game needs DirectX 12",
                "DirectX 12 runs on Apple's D3DMetal, which needs DirectX 12 setup.",
                d3dMetalAvailable ? .useBackend(.d3dMetal) : .setUpDirectX12, e)
        } else if probe?.usesDirectX12 == true, !d3dMetalAvailable, launch?.backend != GraphicsBackend.d3dMetal.rawValue {
            add("needs-dx12", "The game uses DirectX 12",
                "DirectX 12 runs on Apple's D3DMetal, which needs DirectX 12 setup.", .setUpDirectX12, nil)
        }
        if let e = line("VK_ERROR_DEVICE_LOST") {
            add("device-lost", "The graphics driver stopped responding",
                "The game's graphics crashed under Vulkan. Another Graphics option may work better.",
                launch?.backend == GraphicsBackend.dxvk.rawValue && dxmtAvailable ? .useBackend(.dxmt) : .reportProblem, e)
        }
        // Batman: Arkham Knight on DXVK: Metal rejects shaders MoltenVK translated, so whatever they draw is missing.
        if launch?.backend == GraphicsBackend.dxvk.rawValue,
           let e = line("Shader library compile failed") ?? line("Render pipeline compile failed") {
            add("mvk-pipelines", "Parts of the picture can't be drawn",
                "Some of the game's shaders don't translate from Vulkan to Metal, so objects or effects can be missing. DXMT translates DirectX 11 to Metal directly.",
                dxmtAvailable ? .useBackend(.dxmt) : .installExtendedEngine, e)
        }
        if let e = line("ImportSharedTexture: Invalid shared handle type") {
            // Seen with The Lion's Song: its video player decodes into a shared Direct3D 9 surface and opens it in
            // Direct3D 11. Wine's Direct3D 9 doesn't share surfaces yet, so the handle is empty and the game crashes.
            add("d3d9-shared-video", "The game's videos can't be shown yet",
                "The game hands its video frames from DirectX 9 to DirectX 11, which Wine doesn't support yet. It closes when a video starts; there's no setting that fixes this.",
                .none, e)
        }
        if !found.contains(where: { $0.id == "vulkan-32bit" || $0.id == "wined3d-level" }),
           let e = line("Failed to initialize graphics") ?? line("Failed to create D3D11 device") ?? line("D3D11CoreCreateDevice: Failed") {
            add("no-device", "The game couldn't start its graphics",
                "Its Direct3D device couldn't be created with the current Graphics option. Try another one.",
                probe?.uses32BitDirect3D11 == true ? (dxmtAvailable ? .useBackend(.dxmt) : .installExtendedEngine) : .useBackend(.dxvk), e)
        }
        for name in ["EasyAntiCheat", "BattlEye", "BEService", "vgk.sys", "Ricochet", "EAAntiCheat", "nProtect", "XIGNCODE"] {
            if let e = line(name) {
                if name == "BattlEye" || name == "BEService", Self.isGTAV(title: title, lines: lines) {
                    // GTA V's BattlEye (since September 2024) guards GTA Online only; Story Mode runs without it.
                    add("anti-cheat-online", "GTA Online can't run on a Mac, but Story Mode can",
                        "GTA Online needs BattlEye, kernel-level anti-cheat that needs Windows itself. Story Mode doesn't: choose Story Mode when the game starts. If the game doesn't start at all, anti-cheat isn't the reason.",
                        .none, e)
                } else {
                    add("anti-cheat", "The game uses anti-cheat that doesn't run on a Mac",
                        "Kernel-level anti-cheat needs Windows itself. There's no setting that fixes this.", .none, e)
                }
                break
            }
        }
        if let e = lines.last(where: { $0.contains("err:module:import_dll") && $0.contains("not found") && !Self.isSteamClientLine($0) }) {
            let dll = e.range(of: #"Library ([^\s]+) "#, options: .regularExpression)
                .map { String(e[$0]).replacingOccurrences(of: "Library ", with: "").trimmingCharacters(in: .whitespaces) }
            add("missing-dll", "A Windows file the game needs is missing",
                "The game looks for \(dll ?? "a DLL") and can't find it. Verifying the game's files in its store, or reinstalling it, usually brings it back.",
                .reportProblem, e)
        }
        // Mafia II: Definitive Edition's launcher (Epic) is a .NET program; Wine stops it before it opens.
        if let e = line("IL-only binary") {
            add("needs-dotnet", "The game needs .NET",
                "Its launcher is a .NET program, and this environment doesn't have Wine Mono, Wine's open-source .NET runtime. Installing it there lets the launcher open.",
                .installDotNet, e)
        }
        // legendary refuses to start an Epic game the store has updated (seen with Alan Wake 2 1.2.10 -> 1.2.11).
        if let e = line("Game is out of date") {
            add("game-update", "The game needs an update",
                "The store released an update for this game, and the game can't start until it's installed.",
                .updateGame, e)
        }
        if let e = line("ShellExecuteEx failed") ?? line("Application could not be started") {
            add("not-found", "The game's program couldn't be started",
                "Windows couldn't find or open the program. The game may not be fully installed; verify or reinstall it.", .reportProblem, e)
        }
        if let launch, launch.bySignal, let seconds = launch.seconds, seconds < 5,
           let update = engineUpdates.first(where: { $0.installed == launch.engine }) {
            // Engine 2.0.1 on macOS 26: ntdll calls pipe2, which macOS 26 doesn't have, and every launch dies at once.
            add("engine-superseded", "Engine \(update.installed) has been replaced",
                "The engine stopped within seconds, before the game ran. MaPC no longer offers engine \(update.installed): \(update.replacement.version) replaces it and fixes problems like this one. Update the engine; your games and their environments stay as they are.",
                .updateEngine(from: update.installed, to: update.replacement.version),
                "[MaPC] Exit status=\(launch.status ?? 0) after \(Int(seconds)) s on engine \(update.installed)")
        } else if let launch, launch.bySignal, let seconds = launch.seconds, seconds < 5 {
            add("engine-crash", "The engine crashed while starting",
                "The engine itself stopped within seconds, before the game ran. This is an engine problem, not the game's: switch engines in Settings › Engine and send a report.",
                .reportProblem, "[MaPC] Exit status=\(launch.status ?? 0) after \(Int(seconds)) s")
        }
        if found.isEmpty, let e = line("Unhandled page fault") ?? line("page fault on")
            ?? lines.last(where: { $0.contains("Unhandled exception") && !$0.contains("0x80000003") }) {
            add("crash", "The game crashed",
                "Windows reported a crash. If it happened when you quit and your progress is saved, it's harmless; otherwise try another Graphics option.",
                .reportProblem, e)
        } else if found.isEmpty, let e = lines.last(where: { $0.contains("Unhandled exception 0x80000003") }) {
            // A breakpoint. In Steam's environment the game's log also holds Steam's own output, and Steam's window
            // helper hits these while restarting, so it isn't necessarily the game.
            add("breakpoint", launch?.environment == "steam" ? "A program stopped unexpectedly" : "The game stopped unexpectedly",
                launch?.environment == "steam"
                    ? "This is often Steam's window helper restarting, which is harmless, or a game crashing as it quits. If the game didn't start at all, try another Graphics option."
                    : "This often happens when a game crashes as it quits. If your progress is saved, it's harmless; otherwise try another Graphics option.",
                .none, e)
        }
        findings = found

        // The excerpt: errors, crashes and MaPC's own lines, without the Vulkan feature lists.
        var seen = Set<String>()
        excerpt = lines.filter { l in
            let interesting = l.hasPrefix("[MaPC]") || l.contains("err:") || l.contains("Unhandled") || l.contains("mvk-error")
                || l.localizedCaseInsensitiveContains("fail") || l.localizedCaseInsensitiveContains("error")
            return interesting && !l.hasPrefix("\t") && seen.insert(Self.trim(l)).inserted
        }.suffix(40).map(Self.trim)
    }

    // MARK: Helpers

    /// A Wine line about one of Steam's own programs (its web helper, service, overlay). A game started in a fresh
    /// Steam shares Steam's log, so their errors aren't the game's. Games themselves live in `Steam\steamapps`.
    static func isSteamClientLine(_ line: String) -> Bool {
        let path = line.lowercased().replacingOccurrences(of: #"\\"#, with: #"\"#)
        return path.contains(#"\steam\"#) && !path.contains(#"\steamapps\"#)
    }

    /// GTA V (Legacy or Enhanced), by its name or by its programs in the log. The "V" must end the word, so
    /// "Grand Theft Auto IV" and "Grand Theft Auto Vice City" don't count.
    static func isGTAV(title: String?, lines: [String]) -> Bool {
        if let title, title.range(of: #"\b(grand theft auto|gta) ?(v|5)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return lines.contains { $0.range(of: #"\b(gta5(_enhanced)?(_be)?|playgtav)\.exe\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func trim(_ line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 240 ? String(t.prefix(240)) + "…" : t
    }

    static func lastLaunch(in lines: [String]) -> Launch? {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("[MaPC] Launch") }) else { return nil }
        var launch = Launch()
        let iso = ISO8601DateFormatter()
        func field(_ name: String, in line: String) -> String? {
            line.range(of: name + "=([^ ]+)", options: .regularExpression).map { String(line[$0].dropFirst(name.count + 1)) }
        }
        let head = lines[start]
        launch.engine = field("engine", in: head)
        launch.backend = field("backend", in: head)
        launch.environment = field("environment", in: head)
        launch.started = head.split(separator: " ").dropFirst(2).first.flatMap { iso.date(from: String($0)) }
        if let exit = lines[start...].first(where: { $0.hasPrefix("[MaPC] Exit") }) {
            launch.ended = exit.split(separator: " ").dropFirst(2).first.flatMap { iso.date(from: String($0)) }
            launch.status = field("status", in: exit).flatMap { Int32($0) }
            launch.bySignal = field("reason", in: exit) == "signal"
        }
        return launch
    }
}
