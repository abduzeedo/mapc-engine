import Foundation
import Testing
@testable import MacadeKit

/// Builds a minimal PE image: DOS stub, PE header, one `.idata` section with the given imports.
func makePE(machine: UInt16 = 0x8664, imports: [String] = [], delayImports: [String] = []) -> Data {
    var d = Data(count: 0x400)
    func put16(_ v: Int, _ o: Int) { d[o] = UInt8(v & 0xff); d[o + 1] = UInt8(v >> 8 & 0xff) }
    func put32(_ v: Int, _ o: Int) { put16(v & 0xffff, o); put16(v >> 16 & 0xffff, o + 2) }
    let is64 = machine != 0x014c
    d[0] = 0x4d; d[1] = 0x5a                                  // "MZ"
    put32(0x80, 0x3c)
    d.replaceSubrange(0x80..<0x84, with: [0x50, 0x45, 0, 0])  // "PE\0\0"
    put16(Int(machine), 0x84)
    put16(1, 0x86)                                            // one section
    let optSize = is64 ? 240 : 224
    put16(optSize, 0x94)
    let opt = 0x98
    put16(is64 ? 0x20b : 0x10b, opt)
    put32(16, opt + (is64 ? 108 : 92))                        // data directory count
    let dirs = opt + (is64 ? 112 : 96)
    // Section `.idata`: RVA 0x1000, raw data at file offset 0x200.
    let sec = opt + optSize
    put32(0x200, sec + 8); put32(0x1000, sec + 12); put32(0x200, sec + 16); put32(0x200, sec + 20)
    put32(0x1000, dirs + 8)                                   // import directory
    put32(0x1080, dirs + 13 * 8)                              // delay-import directory
    var nameRVA = 0x1100
    func writeName(_ s: String) -> Int {
        let rva = nameRVA
        let bytes = Array(s.utf8) + [0]
        d.replaceSubrange((rva - 0x1000 + 0x200)..<(rva - 0x1000 + 0x200 + bytes.count), with: bytes)
        nameRVA += bytes.count
        return rva
    }
    for (i, dll) in imports.enumerated() { put32(writeName(dll), 0x200 + i * 20 + 12) }
    for (i, dll) in delayImports.enumerated() {
        put32(1, 0x280 + i * 32)                              // RVA-based descriptor
        put32(writeName(dll), 0x280 + i * 32 + 4)
    }
    return d
}

@Suite struct PEImageTests {
    @Test func readsMachineAndImports() throws {
        let pe = try #require(PEImage(data: makePE(imports: ["KERNEL32.dll", "d3d12.dll"])))
        #expect(pe.machine == .x86_64)
        #expect(pe.is64Bit)
        #expect(pe.imports == ["kernel32.dll", "d3d12.dll"])
        #expect(pe.imports("D3D12.DLL"))
    }

    @Test func readsDelayLoadImports() throws {
        let pe = try #require(PEImage(data: makePE(imports: ["kernel32.dll"], delayImports: ["d3d12.dll"])))
        #expect(pe.imports("d3d12.dll"))
    }

    @Test func reads32BitImages() throws {
        let pe = try #require(PEImage(data: makePE(machine: 0x014c, imports: ["d3d11.dll"])))
        #expect(pe.machine == .i386)
        #expect(!pe.is64Bit)
        #expect(pe.imports("d3d11.dll"))
    }

    @Test func rejectsNonPEFiles() {
        #expect(PEImage(data: Data("not an exe".utf8)) == nil)
        #expect(PEImage(data: Data(count: 4096)) == nil)
        var truncated = makePE()
        truncated.removeSubrange(0x90...)
        #expect(PEImage(data: truncated) == nil)
    }
}

@Suite struct GraphicsProbeTests {
    func gameFolder(_ files: [String: Data]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        for (path, data) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return dir
    }

    /// Pads an image past the size cut-off for launchers and helpers.
    func big(_ pe: Data) -> Data { pe + Data(count: GraphicsProbe.minimumExecutableSize) }

    @Test func findsDirectX12Game() throws {
        let dir = try gameFolder(["bin/x64_dx12/game.exe": big(makePE(imports: ["d3d12.dll", "dxgi.dll"]))])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir) == GraphicsProbe(usesDirectX12: true, has64BitExecutable: true))
    }

    @Test func directX11GameIsNotDirectX12() throws {
        let dir = try gameFolder(["Game.exe": big(makePE(imports: ["d3d11.dll"]))])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir) == GraphicsProbe(usesDirectX12: false, has64BitExecutable: true))
    }

    @Test func finds32BitDirect3D11Game() throws {
        let dir = try gameFolder(["TLS.exe": big(makePE(machine: 0x014c, imports: ["kernel32.dll", "d3d11.dll"]))])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir) == GraphicsProbe(uses32BitDirect3D11: true))
    }

    /// PUBG keeps BattlEye four folders down, next to its game binary.
    @Test func findsAntiCheatFolders() throws {
        let pubg = try gameFolder(["TslGame/Binaries/Win64/TslGame.exe": big(makePE(imports: ["d3d11.dll"])),
                                   "TslGame/Binaries/Win64/BattlEye/BEClient_x64.dll": Data()])
        defer { try? FileManager.default.removeItem(at: pubg) }
        #expect(GraphicsProbe.scan(pubg) == GraphicsProbe(has64BitExecutable: true, antiCheat: "BattlEye"))
        let eac = try gameFolder(["Game.exe": big(makePE(imports: ["d3d11.dll"])),
                                  "EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe": Data()])
        defer { try? FileManager.default.removeItem(at: eac) }
        #expect(GraphicsProbe.scan(eac).antiCheat == "EasyAntiCheat")
        #expect(GraphicsProbe.antiCheat(named: "start_protected_game.exe", isDirectory: false) == "EasyAntiCheat")
        #expect(GraphicsProbe.antiCheat(named: "battleye", isDirectory: false) == nil)
        let clean = try gameFolder(["Game.exe": big(makePE(imports: ["d3d11.dll"]))])
        defer { try? FileManager.default.removeItem(at: clean) }
        #expect(GraphicsProbe.scan(clean).antiCheat == nil)
    }

    @Test func runtimeLoaded32BitDirect3D11IsFoundByEntryPoint() throws {
        let dir = try gameFolder(["game.exe": big(makePE(machine: 0x014c, imports: ["kernel32.dll"])) + Data("D3D11CreateDevice\0".utf8)])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir).uses32BitDirect3D11)
    }

    @Test func thirtyTwoBitUnityPlayerCounts() throws {
        // Unity's exe is a stub under the size cut-off; the engine is UnityPlayer.dll.
        let dir = try gameFolder(["Game.exe": makePE(machine: 0x014c), "UnityPlayer.dll": makePE(machine: 0x014c, imports: ["d3d11.dll"])])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir).uses32BitDirect3D11)
    }

    @Test func gamesWithA64BitBuildOrOtherAPIsAreNot32BitDirect3D11() throws {
        let both = try gameFolder([
            "bin32/game.exe": big(makePE(machine: 0x014c, imports: ["d3d11.dll"])),
            "bin64/game.exe": big(makePE(imports: ["d3d11.dll"])),
        ])
        let unity64 = try gameFolder(["Game.exe": makePE(), "UnityPlayer.dll": makePE(imports: ["d3d11.dll"])])
        let dx9 = try gameFolder(["COI.exe": big(makePE(machine: 0x014c, imports: ["d3d9.dll"]))])
        defer { for d in [both, unity64, dx9] { try? FileManager.default.removeItem(at: d) } }
        #expect(!GraphicsProbe.scan(both).uses32BitDirect3D11)
        #expect(!GraphicsProbe.scan(unity64).uses32BitDirect3D11)
        #expect(GraphicsProbe.scan(unity64).has64BitExecutable)
        #expect(!GraphicsProbe.scan(dx9).uses32BitDirect3D11)
    }

    @Test func agilitySDKFolderMeansDirectX12() throws {
        let dir = try gameFolder(["Game.exe": big(makePE(imports: ["kernel32.dll"])), "D3D12/D3D12Core.dll": Data([1])])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir).usesDirectX12)
    }

    @Test func directX12HelperImportsCount() throws {
        let dir = try gameFolder(["bin/game.exe": big(makePE(imports: ["kernel32.dll", "amd_fidelityfx_loader_dx12.dll"]))])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir).usesDirectX12)
    }

    @Test func runtimeLoadedDirectX12IsFoundByEntryPoint() throws {
        // Most DX12 games LoadLibrary("d3d12.dll"): only the entry point name is in the binary.
        let dir = try gameFolder(["game.exe": big(makePE(imports: ["kernel32.dll"])) + Data("D3D12CreateDevice\0".utf8)])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir).usesDirectX12)
    }

    @Test func entryPointSearchWorksAcrossChunkBoundaries() throws {
        let needle = Data("D3D12CreateDevice".utf8)
        let dir = try gameFolder(["f.bin": Data(count: 100) + needle + Data(count: 100)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.bin")
        for chunk in [7, 16, 50, 105, 110, 4096] {
            #expect(GraphicsProbe.contains(needle, in: file, chunkSize: chunk), "chunk \(chunk)")
        }
        #expect(!GraphicsProbe.contains(Data("D3D12CreateDeviceX".utf8), in: file, chunkSize: 16))
    }

    @Test func dxilSignerMeansDirectX12() throws {
        let dir = try gameFolder(["Game.exe": big(makePE(imports: ["kernel32.dll"])), "dxilconv7.dll": Data([1])])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir).usesDirectX12)
    }

    @Test func ignoresRedistributablesAndSmallHelpers() throws {
        let dir = try gameFolder([
            "_CommonRedist/DirectX/dxwebsetup.exe": big(makePE(imports: ["d3d12.dll"])),
            "unins000.exe": big(makePE(imports: ["d3d12.dll"])),
            "helper.exe": makePE(imports: ["d3d12.dll"]),
            "Game.exe": big(makePE(imports: ["d3d11.dll"])),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GraphicsProbe.scan(dir) == GraphicsProbe(usesDirectX12: false, has64BitExecutable: true))
    }

    /// Opt-in check against real installed games:
    /// `MACADE_PROBE_DX12=<dir>:<dir> MACADE_PROBE_NOT_DX12=<dir> swift test --filter realGames`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACADE_PROBE_DX12"] != nil))
    func realGames() {
        let env = ProcessInfo.processInfo.environment
        for path in (env["MACADE_PROBE_DX12"] ?? "").split(separator: ":") {
            #expect(GraphicsProbe.scan(URL(fileURLWithPath: String(path))).usesDirectX12, "\(path)")
        }
        for path in (env["MACADE_PROBE_NOT_DX12"] ?? "").split(separator: ":") {
            #expect(!GraphicsProbe.scan(URL(fileURLWithPath: String(path))).usesDirectX12, "\(path)")
        }
    }
}
