import Foundation
import Testing
@testable import MacadeKit

/// Log lines below are taken from real MaPC reports and test runs (paths shortened).
@Suite struct LogDiagnosisTests {
    func ids(_ d: LogDiagnosis) -> [String] { d.findings.map(\.id) }

    @Test func thirtyTwoBitDirect3D11OnDXVK() {
        let log = """
        [MaPC] Launch 2026-10-19T11:03:21Z engine=1.0.0 wine=11.18 (Staging) environment=epic backend=dxvk
        [mvk-error] VK_ERROR_FEATURE_NOT_PRESENT: vkCreateBuffer(): Only external memory handle type VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLBUFFER_BIT_EXT and VK_EXTERNAL_MEMORY_HANDLE_TYPE_MTLHEAP_BIT_EXT are supported.
        err:   D3D11CoreCreateDevice: Failed to create D3D11 device
        [MaPC] Exit 2026-10-19T11:03:42Z pid=7957 status=0 reason=exit
        """
        let d = LogDiagnosis(log: log, probe: GraphicsProbe(uses32BitDirect3D11: true))
        #expect(ids(d) == ["vulkan-32bit"])
        #expect(d.findings[0].action == .installExtendedEngine)
        #expect(LogDiagnosis(log: log, dxmtAvailable: true).findings[0].action == .useBackend(.dxmt))
        #expect(d.launch?.engine == "1.0.0")
        #expect(d.launch?.backend == "dxvk")
        #expect(d.launch?.seconds == 21)
    }

    @Test func engineCrashingAtStart() {
        // Engine 2.0.1 on macOS 26: every launch, including Steam itself.
        let log = """
        [MaPC] Launch 2026-10-19T09:45:25Z engine=2.0.1 wine=11.0 (CrossOver 26.3.0) environment=steam backend=d3dMetal
        msync: bootstrapped mach port on wine-48ffa31-msync.
        msync: up and running.

        [MaPC] Exit 2026-10-19T09:45:25Z pid=92143 status=11 reason=signal
        """
        let d = LogDiagnosis(log: log)
        #expect(ids(d) == ["engine-crash"])
        #expect(d.launch?.bySignal == true)
    }

    @Test func wineD3DFeatureLevel() {
        let log = "009c:err:d3d:wined3d_select_feature_level None of the requested D3D feature levels is supported on this GPU with the current shader backend."
        #expect(LogDiagnosis(log: log).findings.first?.action == .useBackend(.dxvk))
        #expect(LogDiagnosis(log: log, probe: GraphicsProbe(uses32BitDirect3D11: true), dxmtAvailable: true).findings.first?.action == .useBackend(.dxmt))
    }

    @Test func directX12Needed() {
        let log = "GPU does not meet minimal requirements. Support for DirectX 12 is required."
        #expect(LogDiagnosis(log: log).findings.first?.action == .setUpDirectX12)
        #expect(LogDiagnosis(log: log, d3dMetalAvailable: true).findings.first?.action == .useBackend(.d3dMetal))
        #expect(ids(LogDiagnosis(log: "", probe: GraphicsProbe(usesDirectX12: true))) == ["needs-dx12"])
    }

    @Test func missingDLLIsNamed() {
        let log = "0124:err:module:import_dll Library d3dx9_43.dll (which is needed by L\"C:\\\\Game\\\\game.exe\") not found"
        let d = LogDiagnosis(log: log)
        #expect(ids(d) == ["missing-dll"])
        #expect(d.findings[0].detail.contains("d3dx9_43.dll"))
    }

    @Test func antiCheatAndGenericCrash() {
        #expect(ids(LogDiagnosis(log: "Loading EasyAntiCheat_EOS.sys")) == ["anti-cheat"])
        let crash = "wine: Unhandled page fault on write access to 0000000000000006 at address 000000014004EC2F (thread 0598)"
        #expect(ids(LogDiagnosis(log: crash)) == ["crash"])
    }

    @Test func cleanRunHasNoFindingsAndAShortExcerpt() {
        let log = (["[MaPC] Launch 2026-10-19T14:40:17Z engine=2.0.1-dxmt-test wine=11.0 environment=steam backend=dxmt"]
                   + Array(repeating: "\tVK_KHR_maintenance1 v2", count: 500)
                   + ["info:  Using feature level D3D_FEATURE_LEVEL_11_1", "[MaPC] Exit 2026-10-19T14:42:17Z pid=1 status=0 reason=exit"])
            .joined(separator: "\n")
        let d = LogDiagnosis(log: log)
        #expect(d.findings.isEmpty)
        #expect(d.excerpt.count == 2)                   // the two [MaPC] lines; feature lists are left out
        #expect(d.launch?.seconds == 120)
    }
}
