import Foundation

/// Chromium helpers that only draw under Wine on macOS when Chromium's GPU work runs in-process.
///
/// Out of process, Chromium's GPU process paints into windows owned by the browser process, which Wine's
/// Mac driver can't show: the window is on screen but empty. The wrapper (`engine/steamwebhelper-wrapper`, shipped in the
/// app and in newer engines) takes the helper's name, starts `<name>_real.exe` and adds `--in-process-gpu` and
/// software compositing.
/// Steam's own helper is handled by `SteamProvider.ensureWebHelperWrapper`.
public enum ChromiumHelperWrapper {
    /// Bottle-relative helpers to wrap. Rockstar's Social Club draws the Rockstar Games Launcher's sign-in
    /// window; without the wrapper it stays empty and games that need the launcher never start.
    /// Ubisoft Connect's `upc.exe` is itself the Chromium browser process (its helpers, `UplayWebCore.exe`, are
    /// only children), so the flags have to reach upc.exe. Games start it themselves with a `uplay://launch` link,
    /// so MaPC can't add them on the command line. Unwrapped, its window stayed white and the game never started
    /// (Trackmania from Epic, 2026-11-16); with the flags it drew and signed in. Wrapping it in every environment
    /// also covers Ubisoft Connect started by Steam for Steam copies of Ubisoft games.
    static let helpers = [
        "Program Files/Rockstar Games/Social Club/SocialClubHelper.exe",
        "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/upc.exe",
    ]
    /// Built into the generic wrapper; older engines ship one that can only start `steamwebhelper_real.exe`.
    static let marker = Data("macade-chromium-wrapper/2".utf8)

    /// Built from `engine/steamwebhelper-wrapper` into the app's Resources (see project.yml).
    public static var bundledWrapper: URL? { Bundle.main.url(forResource: "chromium-helper-wrapper", withExtension: "exe") }

    /// The wrapper to install: the app's own, else the engine's if it is the generic one.
    static func wrapper(in engine: Engine, bundled: URL? = bundledWrapper) -> Data? {
        let fm = FileManager.default
        for url in [bundled, engine.steamWebHelperWrapper].compactMap({ $0 }) {
            if let data = fm.contents(atPath: url.path), data.range(of: marker) != nil { return data }
        }
        return nil
    }

    /// Puts the wrapper in front of every helper present in `bottle`. Only swaps files, so it is safe while
    /// the bottle runs; a helper the vendor restored (update, repair) is wrapped again on the next launch.
    @discardableResult
    public static func apply(to bottle: Bottle, engine: Engine, bundled: URL? = bundledWrapper) -> [String] {
        if bottle.exists { addSwiftShaderManifests(in: bottle) }
        guard bottle.exists, let wrapper = wrapper(in: engine, bundled: bundled) else { return [] }
        return helpers.filter { path in
            (try? wrap(bottle.driveC.appendingPathComponent(path), with: wrapper)) == true
        }
    }

    /// Folders whose Chromium ships SwiftShader's Vulkan driver (`vk_swiftshader.dll`) without the manifest that names
    /// it. With `--disable-gpu` Chromium still draws its pages through SwiftShader, and without the manifest it finds no
    /// Vulkan driver: Ubisoft Connect's log filled with `VK_KHR_surface not supported` and `gl_factory_win NOTREACHED`,
    /// and its window stayed transparent with only the icon showing, in a new Ubisoft Connect environment (2026-11-16).
    /// The Epic environment's copy, which drew, had the manifest; the installer (175.1.13416) doesn't ship it.
    static let swiftShaderFolders = ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher"]

    /// Chromium's own `vk_swiftshader_icd.json` (106 bytes, no newline), which points at the DLL beside it.
    static let swiftShaderManifest = Data(#"{"file_format_version": "1.0.0", "ICD": {"library_path": ".\\vk_swiftshader.dll", "api_version": "1.0.5"}}"#.utf8)

    /// Writes the manifest next to `vk_swiftshader.dll` where it's missing. Returns the folders it was added to.
    @discardableResult
    static func addSwiftShaderManifests(in bottle: Bottle) -> [String] {
        let fm = FileManager.default
        return swiftShaderFolders.filter { folder in
            let dir = bottle.driveC.appendingPathComponent(folder)
            let manifest = dir.appendingPathComponent("vk_swiftshader_icd.json")
            guard fm.fileExists(atPath: dir.appendingPathComponent("vk_swiftshader.dll").path),
                  !fm.fileExists(atPath: manifest.path) else { return false }
            return (try? swiftShaderManifest.write(to: manifest, options: .atomic)) != nil
        }
    }

    /// Keep the vendor binary in place until its backup and replacement are ready. A failed write
    /// leaves a launchable helper, and a previously interrupted swap can recover from `_real.exe`.
    static func wrap(_ helper: URL, with wrapper: Data, legacyWrapper: Bool = false) throws -> Bool {
        let fm = FileManager.default
        guard !wrapper.isEmpty else { throw WineRunnerError.launchFailed("the Chromium helper wrapper is empty") }
        let real = helper.deletingLastPathComponent()
            .appendingPathComponent(helper.deletingPathExtension().lastPathComponent + "_real.exe")
        guard let current = fm.contents(atPath: helper.path) else {
            guard let saved = fm.contents(atPath: real.path), !saved.isEmpty,
                  saved.range(of: marker) == nil else { return false }
            try wrapper.write(to: helper, options: .atomic)
            return true
        }
        if current.range(of: marker) != nil || (legacyWrapper && current.count < 500_000) {
            guard let saved = fm.contents(atPath: real.path), !saved.isEmpty,
                  saved.range(of: marker) == nil else {
                throw WineRunnerError.launchFailed("the original Chromium helper is missing; repair Steam to download it again")
            }
            guard current != wrapper else { return false }
            try wrapper.write(to: helper, options: .atomic)
            return true
        }
        // Atomic writes do not remove either working executable before the new data is durable.
        try current.write(to: real, options: .atomic)
        try wrapper.write(to: helper, options: .atomic)
        return true
    }
}
