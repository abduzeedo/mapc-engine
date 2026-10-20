import Foundation

/// Optional full video support: the user's own FFmpeg from Intel Homebrew (`ffmpeg@7`) in place of the engines'
/// built-in one.
///
/// MaPC's engines ship FFmpeg with only patent-cleared decoders (see `engine/ffmpeg-decoders.txt`), so videos in
/// H.264, HEVC or WMV9/VC-1 don't play. Those decoders are covered by patent pools and MaPC never distributes
/// them. A user who installs Homebrew's ffmpeg@7 themselves can have the engines use it: MaPC only links the
/// libraries already on their Mac, the same way it uses the D3DMetal they download from Apple.
///
/// Wine's `winedmo.so` finds FFmpeg next to itself first (`@loader_path/`), so the links go in each engine's
/// `lib/wine/x86_64-unix`. Engine files that were there are moved aside and put back when this is turned off.
public struct FullVideoCodecs: Sendable {
    /// FFmpeg 7's libraries, the major versions the engines are built against.
    public static let libraries = ["libavutil.59.dylib", "libavformat.61.dylib", "libavcodec.61.dylib"]
    static let aside = "ffmpeg-bundled"
    static let marker = ".macade-full-video"

    /// Intel Homebrew's prefix. Apple silicon Homebrew (/opt/homebrew) builds arm64 libraries, which Wine can't load.
    public let homebrewLib: URL
    public init(homebrewLib: URL = URL(fileURLWithPath: "/usr/local/opt/ffmpeg@7/lib", isDirectory: true)) {
        self.homebrewLib = homebrewLib
    }

    /// The command that installs it, shown to the user (MaPC never runs it).
    public static let installCommand = "arch -x86_64 /usr/local/bin/brew install ffmpeg@7"

    /// True when Homebrew's ffmpeg@7 is installed with Intel (x86_64) libraries.
    public var isInstalled: Bool {
        Self.libraries.allSatisfy { lib in
            let url = homebrewLib.appendingPathComponent(lib).resolvingSymlinksInPath()
            return (try? MachOHeader.isX86_64(url)) == true
        }
    }

    static func unixFolder(of engine: Engine) -> URL {
        engine.wineRoot.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
    }

    public func isLinked(into engine: Engine) -> Bool {
        FileManager.default.fileExists(atPath: Self.unixFolder(of: engine).appendingPathComponent(Self.marker).path)
    }

    /// Points `engine` at the user's FFmpeg. Engines without FFmpeg support (no `winedmo.so`) are left alone.
    public func link(into engine: Engine) throws {
        let fm = FileManager.default
        let unix = Self.unixFolder(of: engine)
        guard isInstalled, fm.fileExists(atPath: unix.appendingPathComponent("winedmo.so").path) else { return }
        let aside = unix.appendingPathComponent(Self.aside, isDirectory: true)
        for lib in Self.libraries {
            let target = unix.appendingPathComponent(lib)
            let dest = try? fm.destinationOfSymbolicLink(atPath: target.path)
            if dest == homebrewLib.appendingPathComponent(lib).path { continue }
            // The engine's own file, or its symlink to a versioned file (libavcodec.61.19.101.dylib): set it aside.
            if dest != nil || fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: aside, withIntermediateDirectories: true)
                try? fm.removeItem(at: aside.appendingPathComponent(lib))
                try fm.moveItem(at: target, to: aside.appendingPathComponent(lib))
            }
            try fm.createSymbolicLink(at: target, withDestinationURL: homebrewLib.appendingPathComponent(lib))
        }
        try Data("ffmpeg@7 \(homebrewLib.path)\n".utf8).write(to: unix.appendingPathComponent(Self.marker))
    }

    /// Removes the links and puts the engine's own files back.
    public func unlink(from engine: Engine) throws {
        let fm = FileManager.default
        let unix = Self.unixFolder(of: engine)
        guard isLinked(into: engine) else { return }
        let aside = unix.appendingPathComponent(Self.aside, isDirectory: true)
        for lib in Self.libraries {
            let target = unix.appendingPathComponent(lib)
            if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { try fm.removeItem(at: target) }
            let saved = aside.appendingPathComponent(lib)
            // attributesOfItem doesn't follow links: a set-aside relative symlink doesn't resolve from that folder.
            if (try? fm.attributesOfItem(atPath: saved.path)) != nil { try fm.moveItem(at: saved, to: target) }
        }
        try? fm.removeItem(at: aside)
        try fm.removeItem(at: unix.appendingPathComponent(Self.marker))
    }
}

/// Just enough Mach-O reading to tell an x86_64 library from an arm64 one.
enum MachOHeader {
    static func isX86_64(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 8), head.count == 8 else { return false }
        let magic = head.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let cpu = head.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        if magic == 0xfeedfacf { return cpu == 0x01000007 }                 // thin 64-bit, CPU_TYPE_X86_64
        if magic == 0xbebafeca {                                            // fat (big-endian header)
            guard let more = try? handle.read(upToCount: 4096) else { return false }
            let all = head + more
            let count = Int(UInt32(bigEndian: all.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }))
            for i in 0..<min(count, 16) {
                let off = 8 + i * 20
                guard off + 4 <= all.count else { break }
                if UInt32(bigEndian: all.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }) == 0x01000007 { return true }
            }
        }
        return false
    }
}
