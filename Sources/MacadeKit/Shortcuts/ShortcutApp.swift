import Foundation

public enum ShortcutError: LocalizedError, Equatable {
    case invalidGame
    case nameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .invalidGame: "This game can't have a shortcut."
        case .nameTaken(let name): "A different app called \(name) is already in that folder."
        }
    }
}

/// A tiny app that starts one game: double-click it, put it in the Dock, or find it in Spotlight.
/// It holds no game code. Its only program is a script that opens `mapc://play?game=...`, which MaPC handles.
public enum ShortcutApp {
    public static let infoKey = "MaPCShortcutGameID"

    /// `~/Applications/MaPC Games`: in the user's own Applications folder, so no admin password is needed
    /// and Spotlight indexes it.
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MaPC Games", isDirectory: true)
    }

    /// Creates (or replaces our own earlier shortcut for) the game. Returns the app's location.
    /// `icon` is an `.icns` file to copy in, if there is one.
    @discardableResult
    public static func create(title: String, gameID: String, in folder: URL, icon: URL? = nil) throws -> URL {
        guard let link = GameLink.playURL(gameID: gameID), !link.absoluteString.contains("'") else { throw ShortcutError.invalidGame }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = SaveBackupStore.safeTitle(title)
        let target = folder.appendingPathComponent("\(name).app", isDirectory: true)
        if fm.fileExists(atPath: target.path), existingGameID(at: target) != gameID { throw ShortcutError.nameTaken("\(name).app") }

        let staging = folder.appendingPathComponent(".new-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let macOS = staging.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = staging.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let script = "#!/bin/sh\nexec /usr/bin/open '\(link.absoluteString)'\n"
        let launcher = macOS.appendingPathComponent("launch")
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        var info: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": "games.mapc.shortcut.\(SaveBackupStore.safeID(gameID).lowercased())",
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "LSUIElement": true,                  // no Dock bounce, no menu bar: it just hands over to MaPC
            infoKey: gameID,
        ]
        if let icon, fm.fileExists(atPath: icon.path) {
            try fm.copyItem(at: icon, to: resources.appendingPathComponent("AppIcon.icns"))
            info["CFBundleIconFile"] = "AppIcon"
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: staging.appendingPathComponent("Contents/Info.plist"))

        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
        return target
    }

    /// The game a shortcut app starts, if `app` is one of ours.
    public static func existingGameID(at app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist[infoKey] as? String
    }
}
