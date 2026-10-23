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

    @Test func direct3D9SharedVideoSurface() {
        // The Lion's Song on DXMT with GStreamer installed: the video decodes, then the shared surface can't be opened.
        let log = """
        [MaPC] Launch 2026-10-19T19:26:13Z engine=2.0.4-test wine=11.0 (CrossOver 26.3.0) environment=steam backend=dxmt
        info:  Using feature level D3D_FEATURE_LEVEL_10_0
        warn:  ImportSharedTexture: Invalid shared handle type
        0940:0944:err:seh:NtRaiseException Unhandled exception code c0000005 flags 0 addr 0x656410
        """
        let d = LogDiagnosis(log: log)
        #expect(ids(d) == ["d3d9-shared-video"])
        #expect(d.findings[0].action == LogDiagnosis.Action.none)
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

    @Test func crashOnReplacedEnginePointsToTheUpdate() {
        // The MaPC 1.1.5 report on macOS 26.7.1: Steam's environment on 2.0.1, every launch killed by signal 11 at once.
        let log = """
        [MaPC] Launch 2026-10-20T18:02:11Z engine=2.0.1 wine=11.0 (CrossOver 26.3.0) environment=steam backend=d3dMetal
        [MaPC] Exit 2026-10-20T18:02:12Z pid=4410 status=11 reason=signal
        """
        let entry = EngineManifest.Entry(version: "2.0.2", url: URL(string: "https://x/c")!, sha256: "cc", size: 1,
                                         minAppVersion: "1.0.1", backends: ["d3dMetal", "dxmt"])
        let d = LogDiagnosis(log: log, engineUpdates: [.init(installed: "2.0.1", replacement: entry)])
        #expect(ids(d) == ["engine-superseded"])
        #expect(d.findings[0].action == .updateEngine(from: "2.0.1", to: "2.0.2"))
        #expect(d.findings[0].detail.contains("2.0.2"))
        // Without a known replacement it stays the generic engine crash.
        #expect(ids(LogDiagnosis(log: log)) == ["engine-crash"])
        // A replacement for another engine doesn't apply.
        #expect(ids(LogDiagnosis(log: log, engineUpdates: [.init(installed: "1.0.0", replacement: entry)])) == ["engine-crash"])
        // A replaced engine that ran for a while and quit normally isn't blamed.
        let fine = """
        [MaPC] Launch 2026-10-20T18:02:11Z engine=2.0.1 wine=11.0 (CrossOver 26.3.0) environment=steam backend=d3dMetal
        [MaPC] Exit 2026-10-20T18:40:12Z pid=4410 status=0 reason=exit
        """
        #expect(LogDiagnosis(log: fine, engineUpdates: [.init(installed: "2.0.1", replacement: entry)]).findings.isEmpty)
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

    /// Alan Wake 2 after Epic released 1.2.11: legendary stopped before starting Wine.
    @Test func outOfDateEpicGameAsksForTheUpdate() {
        let log = """
        [MaPC] Launch 2026-10-23T20:41:45Z engine=2.0.2 wine=11.0, from CrossOver 26.3.0 source environment=epic backend=d3dMetal
        [cli] INFO: Checking for updates...
        [cli] ERROR: Game is out of date, please update or launch with update check skipping!

        [MaPC] Exit 2026-10-23T20:41:53Z pid=77674 status=1 reason=exit
        """
        let d = LogDiagnosis(log: log)
        #expect(ids(d) == ["game-update"])
        #expect(d.findings[0].action == .updateGame)
        #expect(EpicProvider.needsUpdate(launchOutput: log))
        #expect(!EpicProvider.needsUpdate(launchOutput: "[cli] INFO: Launching 63a6..."))
    }

    /// Mafia II: Definitive Edition on Epic: its launcher is .NET and the environment had no Wine Mono.
    @Test func dotNetLauncherAsksForMono() {
        let log = """
        [MaPC] Launch 2026-10-23T23:14:01Z engine=1.0.1 wine=11.18 (Staging) environment=epic backend=dxvk
        [MaPC] Exit 2026-10-23T23:14:05Z pid=23524 status=0 reason=exit
        0024:err:module:fixup_imports_ilonly mscoree.dll not found, IL-only binary L"Launcher.exe" cannot be loaded
        0024:err:module:loader_init Importing dlls for L"Z:\\Games\\MafiaIIDE\\pc\\Mafia2Launcher\\Launcher.exe" failed, status c0000135
        """
        let d = LogDiagnosis(log: log)
        #expect(ids(d) == ["needs-dotnet"])
        #expect(d.findings[0].action == .installDotNet)
    }

    @Test func missingDLLIsNamed() {
        let log = "0124:err:module:import_dll Library d3dx9_43.dll (which is needed by L\"C:\\\\Game\\\\game.exe\") not found"
        let d = LogDiagnosis(log: log)
        #expect(ids(d) == ["missing-dll"])
        #expect(d.findings[0].detail.contains("d3dx9_43.dll"))
    }

    /// Default logs now keep `err:module`, and a game started in a fresh Steam writes into Steam's log.
    @Test func steamClientMissingDLLIsNotTheGames() {
        let helper = "0130:err:module:import_dll Library dwmapi.dll (which is needed by L\"C:\\\\Program Files (x86)\\\\Steam\\\\bin\\\\cef\\\\cef.win64\\\\steamwebhelper_real.exe\") not found"
        #expect(ids(LogDiagnosis(log: helper)).isEmpty)
        let game = "0124:err:module:import_dll Library d3dx9_43.dll (which is needed by L\"C:\\\\Program Files (x86)\\\\Steam\\\\steamapps\\\\common\\\\Game\\\\game.exe\") not found"
        #expect(ids(LogDiagnosis(log: helper + "\n" + game)) == ["missing-dll"])
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
