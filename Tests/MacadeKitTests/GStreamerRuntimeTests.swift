import Foundation
import Testing
@testable import MacadeKit

@Suite struct GStreamerRuntimeTests {
    let fm = FileManager.default

    func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v) { Data($0) } }

    /// A universal (fat) header with arm64 and, optionally, x86_64 slices.
    func fat(withIntel: Bool) -> Data {
        let cpus: [UInt32] = withIntel ? [0x0100000c, 0x01000007] : [0x0100000c]
        var d = be32(0xcafebabe) + be32(UInt32(cpus.count))
        for cpu in cpus { d += be32(cpu) + be32(3) + be32(0x4000) + be32(0x100) + be32(14) }
        return d
    }

    func framework(_ lib: Data?, libav: Bool = true, version: String? = "1.28.8") throws -> GStreamerRuntime {
        let root = fm.temporaryDirectory.appendingPathComponent("gst-\(UUID().uuidString)/GStreamer.framework")
        let libs = root.appendingPathComponent("Libraries/gstreamer-1.0")
        try fm.createDirectory(at: libs, withIntermediateDirectories: true)
        if let lib { try lib.write(to: root.appendingPathComponent("Libraries/libgstreamer-1.0.0.dylib")) }
        if libav { try Data([1]).write(to: libs.appendingPathComponent("libgstlibav.dylib")) }
        if let version {
            let res = root.appendingPathComponent("Versions/1.0/Resources")
            try fm.createDirectory(at: res, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try plist.write(to: res.appendingPathComponent("Info.plist"))
        }
        return GStreamerRuntime(framework: root)
    }

    @Test func universalFrameworkIsInstalled() throws {
        let g = try framework(fat(withIntel: true))
        defer { try? fm.removeItem(at: g.framework.deletingLastPathComponent()) }
        #expect(g.isInstalled)
        #expect(g.hasLibav)
        #expect(g.version == "1.28.8")
    }

    @Test func armOnlyOrMissingIsNotInstalled() throws {
        let arm = try framework(fat(withIntel: false))
        let thinIntel = try framework(le32(0xfeedfacf) + le32(0x01000007), libav: false, version: nil)
        let missing = try framework(nil)
        defer { for g in [arm, thinIntel, missing] { try? fm.removeItem(at: g.framework.deletingLastPathComponent()) } }
        #expect(!arm.isInstalled)
        #expect(thinIntel.isInstalled)
        #expect(!thinIntel.hasLibav)
        #expect(thinIntel.version == nil)
        #expect(!missing.isInstalled)
    }
}
