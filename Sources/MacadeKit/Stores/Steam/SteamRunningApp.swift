import Foundation

/// Steam writes the id of the game it is running to `RunningAppID` in the bottle's registry file
/// (0 when none). Wine saves that file every few seconds, so reading it tells MaPC when a Steam game
/// starts and stops, which Steam's own process can't.
public enum SteamRunningApp {
    private static let marker = Array(#""RunningAppID"=dword:"#.utf8)

    /// The running app's id, or nil when none is running (or the value is missing).
    public static func parse(registry data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let at = find(marker, in: bytes) else { return nil }
        let start = at + marker.count
        guard start + 8 <= bytes.count,
              let hex = String(bytes: bytes[start..<start + 8], encoding: .ascii),
              let value = UInt32(hex, radix: 16), value != 0 else { return nil }
        return String(value)
    }

    public static func read(bottle: Bottle) -> String? {
        guard let data = try? Data(contentsOf: bottle.url.appendingPathComponent("user.reg"), options: .mappedIfSafe) else { return nil }
        return parse(registry: data)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            if haystack[i] == needle[0], haystack[i..<i + needle.count].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }
}
