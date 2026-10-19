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

    public static func note(for game: Game, remote: [String: String]? = nil, probe: GraphicsProbe? = nil,
                            d3dMetalAvailable: Bool = false, dxmtAvailable: Bool = false) -> String? {
        if let note = remote?[game.id] ?? builtIn[game.id] { return note }
        if probe?.usesDirectX12 == true && !d3dMetalAvailable { return needsDirectX12Engine }
        if probe?.uses32BitDirect3D11 == true && !dxmtAvailable { return needs32BitDirect3D11Engine }
        return nil
    }
}
