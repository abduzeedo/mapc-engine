import Foundation

/// Plain-language compatibility notes (plan §5 error UX). The remote manifest can add or override entries.
public enum KnownIssues {
    public static let builtIn: [String: String] = [
        "epic:Fortnite": "Fortnite uses kernel-level anti-cheat that doesn't run on macOS.",
    ]

    /// Shown for DirectX 12 games (found by `GraphicsProbe`) while no D3DMetal engine is installed.
    public static let needsDirectX12Engine =
        "This game uses DirectX 12. DirectX 12 compatibility is an advanced option that needs Apple's D3DMetal, which you install yourself under Apple's license."

    public static func note(for game: Game, remote: [String: String]? = nil,
                            probe: GraphicsProbe? = nil, d3dMetalAvailable: Bool = false) -> String? {
        if let note = remote?[game.id] ?? builtIn[game.id] { return note }
        return probe?.usesDirectX12 == true && !d3dMetalAvailable ? needsDirectX12Engine : nil
    }
}
