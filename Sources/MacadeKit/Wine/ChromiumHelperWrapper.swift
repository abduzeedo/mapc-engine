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
    static let helpers = ["Program Files/Rockstar Games/Social Club/SocialClubHelper.exe"]
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
        guard bottle.exists, let wrapper = wrapper(in: engine, bundled: bundled) else { return [] }
        return helpers.filter { path in
            (try? wrap(bottle.driveC.appendingPathComponent(path), with: wrapper)) == true
        }
    }

    /// Swaps `helper` for `wrapper`, keeping the vendor's binary as `<name>_real.exe`. A helper that is
    /// already a wrapper (it carries the marker) is only refreshed. Returns true if anything changed.
    static func wrap(_ helper: URL, with wrapper: Data) throws -> Bool {
        let fm = FileManager.default
        guard let current = fm.contents(atPath: helper.path) else { return false }
        if current.range(of: marker) != nil {
            guard current != wrapper else { return false }
            try wrapper.write(to: helper, options: .atomic)
            return true
        }
        let real = helper.deletingLastPathComponent()
            .appendingPathComponent(helper.deletingPathExtension().lastPathComponent + "_real.exe")
        try? fm.removeItem(at: real)
        try fm.moveItem(at: helper, to: real)
        try wrapper.write(to: helper, options: .atomic)
        return true
    }
}
