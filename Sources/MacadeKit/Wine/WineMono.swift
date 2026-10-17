import Foundation
import CryptoKit

/// Wine Mono, Wine's open-source .NET runtime. Programs with managed code need it: the EA app's installer
/// runs a .NET custom action and fails with error 1603 without it (the same reason Mafia: Definitive
/// Edition's launcher won't start). Downloaded once from WineHQ, checked against the SHA-256 Wine itself
/// pins for this version, and installed per bottle that needs it.
public struct WineMono: Sendable {
    /// The version Wine 11 expects (`MONO_VERSION` and `MONO_SHA` in Wine's `dlls/appwiz.cpl/addons.c`).
    public static let version = "10.4.1"
    public static let sha256 = "071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23"
    public static let downloadURL = URL(string: "https://dl.winehq.org/wine/wine-mono/\(version)/wine-mono-\(version)-x86.msi")!

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var cachedInstaller: URL { paths.tools.appendingPathComponent("wine-mono-\(Self.version)-x86.msi") }

    static func digest(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }

    /// The verified installer, downloading it first when it isn't cached (or the cached copy is damaged).
    func verifiedInstaller() async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: cachedInstaller.path) {
            if (try? Self.digest(of: cachedInstaller)) == Self.sha256 { return cachedInstaller }
            try? fm.removeItem(at: cachedInstaller)
        }
        let (tmp, response) = try await URLSession.shared.download(from: Self.downloadURL)
        defer { try? fm.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WineRunnerError.launchFailed("couldn't download the .NET runtime (Wine Mono)")
        }
        guard try Self.digest(of: tmp) == Self.sha256 else {
            throw WineRunnerError.launchFailed("the downloaded .NET runtime failed its integrity check")
        }
        try fm.createDirectory(at: paths.tools, withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: cachedInstaller)
        return cachedInstaller
    }

    /// Installs Wine Mono into `bottle`. Does nothing when it's already there.
    public func ensureInstalled(in bottle: Bottle, engine: Engine) async throws {
        guard !bottle.hasMono else { return }
        let installer = try await verifiedInstaller()
        var env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        env["WINEDLLOVERRIDES"] = "mshtml=;winemenubuilder.exe=d"   // the MSI itself must not be held back
        let windowsPath = "Z:" + installer.path.replacingOccurrences(of: "/", with: "\\")
        let result = try await ProcessRunner.run(engine.wine, ["msiexec", "/i", windowsPath, "/qn"], environment: env)
        guard result.succeeded, bottle.hasMono else {
            throw WineRunnerError.launchFailed("couldn't install the .NET runtime (Wine Mono)")
        }
    }
}
