import Foundation
import Testing
@testable import MacadeKit

@Suite struct FullVideoCodecsTests {
    let fm = FileManager.default

    /// A thin x86_64 Mach-O header followed by a body that tells the files apart.
    func machO(_ body: String, cpu: UInt32 = 0x01000007) -> Data {
        var d = Data()
        withUnsafeBytes(of: UInt32(0xfeedfacf)) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: cpu) { d.append(contentsOf: $0) }
        return d + Data(body.utf8)
    }

    func fixture(arch: UInt32 = 0x01000007) throws -> (root: URL, engine: Engine, codecs: FullVideoCodecs) {
        let root = fm.temporaryDirectory.appendingPathComponent("fullvideo-\(UUID().uuidString)")
        let brew = root.appendingPathComponent("usr/local/opt/ffmpeg@7/lib")
        try fm.createDirectory(at: brew, withIntermediateDirectories: true)
        for lib in FullVideoCodecs.libraries { try machO("brew \(lib)", cpu: arch).write(to: brew.appendingPathComponent(lib)) }
        let engineDir = root.appendingPathComponent("Engines/2.0.3-test")
        let unix = engineDir.appendingPathComponent("wine/lib/wine/x86_64-unix")
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)
        try fm.createDirectory(at: engineDir.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        try #"{"version":"2.0.3-test","wineVersion":"11","backends":["d3dMetal","dxmt"],"minMacOS":"14.0"}"#
            .write(to: engineDir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        try machO("winedmo").write(to: unix.appendingPathComponent("winedmo.so"))
        for lib in FullVideoCodecs.libraries { try machO("bundled \(lib)").write(to: unix.appendingPathComponent(lib)) }
        return (root, try #require(Engine(directory: engineDir)), FullVideoCodecs(homebrewLib: brew))
    }

    @Test func linksHomebrewAndPutsTheEnginesFilesBack() throws {
        let (root, engine, codecs) = try fixture()
        defer { try? fm.removeItem(at: root) }
        #expect(codecs.isInstalled)
        try codecs.link(into: engine)
        let unix = FullVideoCodecs.unixFolder(of: engine)
        let avcodec = unix.appendingPathComponent("libavcodec.61.dylib")
        #expect(try fm.destinationOfSymbolicLink(atPath: avcodec.path) == codecs.homebrewLib.appendingPathComponent("libavcodec.61.dylib").path)
        #expect(codecs.isLinked(into: engine))
        try codecs.link(into: engine)                                   // again: no change, no error
        try codecs.unlink(from: engine)
        #expect(fm.contents(atPath: avcodec.path) == machO("bundled libavcodec.61.dylib"))
        #expect(!codecs.isLinked(into: engine))
        #expect(!fm.fileExists(atPath: unix.appendingPathComponent(FullVideoCodecs.aside).path))
    }

    @Test func enginesVersionedSymlinksAreSetAsideNotDeleted() throws {
        // Engine 1.x ships libavcodec.61.dylib as a symlink to libavcodec.61.19.101.dylib.
        let (root, engine, codecs) = try fixture()
        defer { try? fm.removeItem(at: root) }
        let unix = FullVideoCodecs.unixFolder(of: engine)
        let link = unix.appendingPathComponent("libavcodec.61.dylib")
        try fm.removeItem(at: link)
        try machO("bundled versioned").write(to: unix.appendingPathComponent("libavcodec.61.19.101.dylib"))
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "libavcodec.61.19.101.dylib")
        try codecs.link(into: engine)
        try codecs.unlink(from: engine)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == "libavcodec.61.19.101.dylib")
        #expect(fm.contents(atPath: link.path) == machO("bundled versioned"))
    }

    @Test func armHomebrewOrNoWinedmoIsIgnored() throws {
        let (root, engine, codecs) = try fixture(arch: 0x0100000c)      // arm64: Wine can't load it
        defer { try? fm.removeItem(at: root) }
        #expect(!codecs.isInstalled)
        try codecs.link(into: engine)
        #expect(!codecs.isLinked(into: engine))

        let (root2, engine2, codecs2) = try fixture()
        defer { try? fm.removeItem(at: root2) }
        try fm.removeItem(at: FullVideoCodecs.unixFolder(of: engine2).appendingPathComponent("winedmo.so"))
        try codecs2.link(into: engine2)
        #expect(!codecs2.isLinked(into: engine2))
    }
}
