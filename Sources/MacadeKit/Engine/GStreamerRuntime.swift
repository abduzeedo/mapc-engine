import Foundation

/// Game videos need GStreamer: Wine's Media Foundation decodes video and audio through `winegstreamer`, which
/// loads `/Library/Frameworks/GStreamer.framework`. MaPC doesn't ship GStreamer or any codec. Users who want game
/// videos install the official, universal GStreamer runtime from gstreamer.freedesktop.org themselves; this only
/// looks at what is installed.
public struct GStreamerRuntime: Sendable, Equatable {
    public static let downloadPage = URL(string: "https://gstreamer.freedesktop.org/download/#macos")!

    public let framework: URL
    public init(framework: URL = URL(fileURLWithPath: "/Library/Frameworks/GStreamer.framework", isDirectory: true)) {
        self.framework = framework
    }

    var libraries: URL { framework.appendingPathComponent("Libraries", isDirectory: true) }

    /// Installed with Intel (x86_64) code, which Wine runs under Rosetta. The official package is universal.
    public var isInstalled: Bool {
        (try? MachOHeader.hasX86_64(libraries.appendingPathComponent("libgstreamer-1.0.0.dylib").resolvingSymlinksInPath())) == true
    }

    /// The FFmpeg-based codec plugin (gst-libav) that decodes formats like H.264 and WMV9.
    public var hasLibav: Bool {
        FileManager.default.fileExists(atPath: libraries.appendingPathComponent("gstreamer-1.0/libgstlibav.dylib").path)
    }

    /// The installed version, from the framework's Info.plist.
    public var version: String? {
        let plists = ["Versions/1.0/Resources/Info.plist", "Resources/Info.plist"].map { framework.appendingPathComponent($0) }
        for url in plists {
            if let data = try? Data(contentsOf: url),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let v = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String { return v }
        }
        return nil
    }
}

/// Just enough Mach-O reading to tell whether a library has an x86_64 slice.
enum MachOHeader {
    static let x86_64: UInt32 = 0x01000007

    static func hasX86_64(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        guard data.count >= 8 else { return false }
        func le(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func be(_ o: Int) -> UInt32 { UInt32(bigEndian: le(o)) }
        if le(0) == 0xfeedfacf { return le(4) == x86_64 }                   // thin 64-bit
        if be(0) == 0xcafebabe || be(0) == 0xcafebabf {                      // fat (32- or 64-bit offsets)
            let entry = be(0) == 0xcafebabe ? 20 : 32
            for i in 0..<Int(min(be(4), 16)) where 8 + i * entry + 4 <= data.count {
                if be(8 + i * entry) == x86_64 { return true }
            }
        }
        return false
    }
}
