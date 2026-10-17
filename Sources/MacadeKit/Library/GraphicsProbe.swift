import Foundation

/// What a game's files say about the graphics it needs. Stores don't publish this, so Macade looks
/// at the executables and the files shipped next to them. Pure file reads; nothing is executed.
public struct GraphicsProbe: Codable, Sendable, Equatable {
    /// The game uses (or can use) Direct3D 12. Most DX12 games load `d3d12.dll` at run time,
    /// so this also counts DX12-only helper libraries and the `D3D12CreateDevice` entry point.
    public var usesDirectX12 = false
    public var has64BitExecutable = false

    public init(usesDirectX12: Bool = false, has64BitExecutable: Bool = false) {
        self.usesDirectX12 = usesDirectX12
        self.has64BitExecutable = has64BitExecutable
    }

    /// Folders that hold installers, crash reporters and anti-cheat rather than the game.
    static let skippedFolders = ["redist", "directx", "vcredist", "prereq", "installer", "support",
                                 "easyanticheat", "battleye", "crashreport", "thirdparty", "__overlay"]
    static let skippedNames = ["unins", "setup", "redist", "crash", "report", "vc_", "dxsetup", "dotnet", "ue4prereq"]
    /// Launchers and helpers are small; real game binaries are not.
    static let minimumExecutableSize = 1_500_000
    /// Files only Direct3D 12 games ship: the Agility SDK runtime and the DXIL signer/converter.
    static func isDirectX12File(_ name: String, folder: String) -> Bool {
        (name == "d3d12core.dll" && folder == "d3d12") || name == "dxil.dll" || (name.hasPrefix("dxilconv") && name.hasSuffix(".dll"))
    }
    static func isDirectX12Import(_ dll: String) -> Bool { dll.contains("d3d12") || dll.contains("_dx12") }

    public static func scan(_ directory: URL, maxDepth: Int = 4, maxExecutables: Int = 32) -> GraphicsProbe {
        var probe = GraphicsProbe()
        var executables: [(url: URL, image: PEImage)] = []
        let base = directory.standardizedFileURL.pathComponents.count
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return probe }

        for case let url as URL in walker {
            let name = url.lastPathComponent.lowercased()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                let depth = url.standardizedFileURL.pathComponents.count - base
                if depth >= maxDepth || skippedFolders.contains(where: name.contains) { walker.skipDescendants() }
                continue
            }
            if isDirectX12File(name, folder: url.deletingLastPathComponent().lastPathComponent.lowercased()) {
                probe.usesDirectX12 = true
            }
            guard url.pathExtension.lowercased() == "exe", executables.count < maxExecutables,
                  (values?.fileSize ?? 0) >= minimumExecutableSize,
                  !skippedNames.contains(where: name.contains),
                  let image = PEImage(url: url) else { continue }
            executables.append((url, image))
            if image.is64Bit { probe.has64BitExecutable = true }
            if image.imports.contains(where: isDirectX12Import) { probe.usesDirectX12 = true }
        }
        // Last resort, and the slow part (game executables can be hundreds of MB): look for the entry point.
        if !probe.usesDirectX12 {
            probe.usesDirectX12 = executables.contains { contains(Data("D3D12CreateDevice".utf8), in: $0.url) }
        }
        return probe
    }

    /// Streams `file` looking for `needle`, in chunks that overlap by the needle's length.
    static func contains(_ needle: Data, in file: URL, chunkSize: Int = 8 << 20) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var carry = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            let window = carry + chunk
            let found = window.withUnsafeBytes { hay in
                needle.withUnsafeBytes { n in
                    memmem(hay.baseAddress, hay.count, n.baseAddress, n.count) != nil
                }
            }
            if found { return true }
            carry = window.suffix(needle.count - 1)
        }
        return false
    }
}
