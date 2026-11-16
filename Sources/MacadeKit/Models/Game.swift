import Foundation

public enum StoreKind: String, Codable, Sendable, CaseIterable {
    case steam, epic, gog, amazon, ubisoft, ea

    public var displayName: String {
        switch self {
        case .steam: "Steam"
        case .epic: "Epic Games"
        case .gog: "GOG"
        case .amazon: "Amazon Games"
        case .ubisoft: "Ubisoft Connect"
        case .ea: "EA app"
        }
    }

    /// Each store runs in its own Windows environment.
    public var bottleKind: BottleKind { BottleKind(rawValue: rawValue)! }

    /// Stores whose own Windows launcher runs the games (games share its environment and engine).
    public var usesLauncher: Bool { self == .steam || self == .ubisoft || self == .ea }
}

public struct Game: Identifiable, Codable, Hashable, Sendable {
    public let id: String          // "<store>:<id>", e.g. "steam:268910", "epic:<app_name>", "gog:1207658924"
    public let store: StoreKind
    public var storeID: String     // appid / app_name
    public var title: String
    public var isInstalled: Bool
    public var installPath: URL?
    public var sizeOnDisk: Int64?
    public var coverURL: URL?
    public var heroURL: URL?
    /// 0...1 while the store is installing or updating this game.
    public var installProgress: Double?
    /// Another store's launcher the game needs running, though a different store sold it: Ubisoft Connect for
    /// Ubisoft games bought on Epic.
    public var requiredLauncher: StoreKind?

    public init(store: StoreKind, storeID: String, title: String, isInstalled: Bool,
                installPath: URL? = nil, sizeOnDisk: Int64? = nil,
                coverURL: URL? = nil, heroURL: URL? = nil, installProgress: Double? = nil,
                requiredLauncher: StoreKind? = nil) {
        self.id = "\(store.rawValue):\(storeID)"
        self.store = store
        self.storeID = storeID
        self.title = title
        self.isInstalled = isInstalled
        self.installPath = installPath
        self.sizeOnDisk = sizeOnDisk
        self.coverURL = coverURL
        self.heroURL = heroURL
        self.installProgress = installProgress
        self.requiredLauncher = requiredLauncher
    }
}
