import Foundation

public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    case auto, d3dMetal, dxmt, dxvk, wined3d

    public var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .d3dMetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .wined3d: "WineD3D"
        }
    }

    /// Resolves `.auto` for a game. DXVK (on DXVK-macOS 1.10.3) only reaches Direct3D 11 feature level 11.0
    /// and has no Direct3D 12, so DirectX 12 games go to Apple's D3DMetal whenever an engine provides it.
    /// 32-bit Direct3D 10/11 games go to DXMT, the only backend that can create their device (see `GraphicsProbe`).
    /// Games in `dxmtGames` go to DXMT too. Everything else stays on DXVK, which is what the games verified so far
    /// were tested with.
    public func resolved(for probe: GraphicsProbe? = nil, d3dMetalAvailable: Bool = false,
                         dxmtAvailable: Bool = false, gameID: String? = nil) -> GraphicsBackend {
        guard self == .auto else { return self }
        if d3dMetalAvailable && probe?.usesDirectX12 == true { return .d3dMetal }
        if dxmtAvailable && probe?.uses32BitDirect3D11 == true { return .dxmt }
        if dxmtAvailable, let gameID, Self.dxmtGames.contains(gameID) { return .dxmt }
        return .dxvk
    }

    /// 64-bit DirectX 11 games that run on DXMT but not on DXVK, by `Game.id`. Batman: Arkham Knight: MoltenVK can't
    /// compile about a thousand of its pipelines (Metal rejects the translated shaders), so Batman has no cape.
    public static let dxmtGames: Set<String> = ["epic:Cowbird", "steam:208650"]

    /// Extra `WINEDLLOVERRIDES` entries and environment for this backend.
    var overrides: [String] {
        switch self {
        case .dxvk: ["d3d11,d3d10core=n,b"]
        case .dxmt: ["dxgi,d3d11,d3d10core=n,b"]
        default: []
        }
    }

    var environment: [String: String] {
        switch self {
        case .dxvk: ["DXVK_ASYNC": "1", "MVK_CONFIG_RESUME_LOST_DEVICE": "1"]
        default: [:]
        }
    }
}
