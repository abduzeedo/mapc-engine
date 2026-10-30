import Foundation

/// Makes Wine's native dialogs (file browser, comctl32 UI) show CJK text.
///
/// `MS Shell Dlg` substitutes to `Tahoma`. When a glyph is missing, Wine walks that font's system link list
/// (`load_system_links` and `create_child_font_list` in `dlls/win32u/font.c`), read from
/// `HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink`. Wine's default list names only
/// Windows font files (`MSGOTHIC.TTC`, `MSJH.TTC`, …) that a bottle doesn't have, so every link fails.
/// Wine does register the Mac's own CJK fonts as external fonts, so we put those first.
///
/// An entry is `<file basename>,<family name>`. Wine resolves it with `find_face_from_filename(file, family)`:
/// the second field is the FAMILY name (`Heiti TC`), never a face name (`Heiti TC Medium` silently fails).
public enum FontLinks {
    static let systemLinkKey = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
    /// Fonts that get the link list.
    static let faces = ["Tahoma", "Microsoft Sans Serif"]

    /// The Mac's CJK fonts, tried first.
    static let macEntries = [
        "STHeiti Medium.ttc,Heiti TC",
        "STHeiti Medium.ttc,Heiti SC",
        "ヒラギノ角ゴシック W4.ttc,Hiragino Sans",
        "AppleSDGothicNeo.ttc,Apple SD Gothic Neo",
    ]

    /// Wine's own defaults for Tahoma, kept after the Mac fonts so nothing is lost.
    static let wineDefaults = [
        "MSGOTHIC.TTC,MS UI Gothic",
        "MINGLIU.TTC,PMingLiU",
        "SIMSUN.TTC,SimSun",
        "GULIM.TTC,Gulim",
        "YUGOTHM.TTC,Yu Gothic UI",
        "MSJH.TTC,Microsoft JhengHei UI",
        "MSYH.TTC,Microsoft YaHei UI",
        "MALGUN.TTF,Malgun Gothic",
        "SEGUISYM.TTF,Segoe UI Symbol",
    ]

    /// `reg add` turns the two characters `\0` into the REG_MULTI_SZ separator.
    static var data: String { (macEntries + wineDefaults).joined(separator: #"\0"#) }

    /// One `reg add` per face.
    static func registryCommands() -> [[String]] {
        faces.map { ["reg", "add", systemLinkKey, "/v", $0, "/t", "REG_MULTI_SZ", "/d", data, "/f"] }
    }
}

public extension WineRunner {
    /// Writes the CJK font links into a bottle. Wine reads them when it starts; failures are ignored.
    func applyFontLinks(engine: Engine, bottle: Bottle) async {
        let env = Self.environment(bottle: bottle, profile: LaunchProfile())
        for arguments in FontLinks.registryCommands() {
            _ = try? await ProcessRunner.run(engine.wine, arguments, environment: env)
        }
    }
}
