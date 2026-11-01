import Foundation

/// Plain-language compatibility notes (plan §5 error UX). The remote manifest can add or override entries.
public enum KnownIssues {
    public static let builtIn: [String: String] = [
        "epic:Fortnite": "Fortnite uses kernel-level anti-cheat that doesn't run on macOS.",
    ]

    /// Shown for DirectX 12 games (found by `GraphicsProbe`) while no D3DMetal engine is installed.
    public static let needsDirectX12Engine =
        "This game uses DirectX 12. DirectX 12 compatibility is an advanced option that needs Apple's D3DMetal, which you install yourself under Apple's license."

    /// Shown for 32-bit Direct3D 10/11 games (found by `GraphicsProbe`) while no engine runs them (DXMT).
    public static let needs32BitDirect3D11Engine =
        "This is a 32-bit DirectX 10/11 game. It needs MaPC's extended engine, a free download; without it the game closes right after it starts."

    /// Shown for games that ship kernel-level anti-cheat (found by `GraphicsProbe`). Not "can't run": some games
    /// use it only for online modes (GTA V's Story Mode runs without its BattlEye).
    public static func antiCheatNote(_ antiCheat: String) -> String {
        "This game includes \(antiCheat) anti-cheat, which needs Windows itself and doesn't run on a Mac. If the game needs it to play, it closes soon after it starts. Some games use it only for online play."
    }

    public static func note(for game: Game, remote: [String: String]? = nil, probe: GraphicsProbe? = nil,
                            d3dMetalAvailable: Bool = false, dxmtAvailable: Bool = false) -> String? {
        if let note = remote?[game.id] ?? builtIn[game.id] { return note }
        if let antiCheat = probe?.antiCheat { return antiCheatNote(antiCheat) }
        if probe?.usesDirectX12 == true && !d3dMetalAvailable { return needsDirectX12Engine }
        if probe?.uses32BitDirect3D11 == true && !dxmtAvailable { return needs32BitDirect3D11Engine }
        return nil
    }
}
