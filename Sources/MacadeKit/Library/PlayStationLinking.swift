import Foundation

/// Sony games that need a PlayStation Network account and sign in through the PlayStation PC SDK.
///
/// Under Wine the SDK's own sign-in fails: Horizon Zero Dawn Remastered from Epic says the PlayStation SDK hit an error
/// and never offers PSN sign-in (Tanmay, MaPC 1.1.33, 2026-11-21); Proton players with the Epic copy see "something went
/// wrong initialising the API". The game's `-showlinkingqr` option shows a QR code and link instead, so the account is
/// linked on a phone or in a browser and the SDK's sign-in isn't needed (Proton issue 8205, Nixxes on Steam's forum).
public enum PlayStationLinking {
    /// Game ids (`Game.id`) that take `-showlinkingqr`.
    static let games: Set<String> = [
        "epic:4af7cb19d9db48878d2ffe0edc8440a2",   // Horizon Zero Dawn Remastered
        "steam:2561580",                           // Horizon Zero Dawn Remastered
    ]
    static let argument = "-showlinkingqr"

    /// Extra arguments for `game`, unless the user already passes the option.
    public static func arguments(for game: Game, userArguments: [String]) -> [String] {
        guard games.contains(game.id),
              !userArguments.contains(where: { $0.caseInsensitiveCompare(argument) == .orderedSame }) else { return [] }
        return [argument]
    }

    /// Shown on the game's page.
    public static let note =
        "This game needs a PlayStation Network account. MaPC starts it with a QR code for linking: scan it with your phone, or open the link it shows, and sign in there. The \"No installed graphics card has been detected\" message at start is harmless on a Mac: press OK and the game runs."

    static func note(for game: Game) -> String? { games.contains(game.id) ? note : nil }
}
