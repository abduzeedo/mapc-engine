import Foundation

/// What every store backend offers. Steam and Epic implement it; GOG etc. could follow.
public protocol StoreProvider: Sendable {
    var kind: StoreKind { get }
    func refresh() async throws -> [Game]
}
