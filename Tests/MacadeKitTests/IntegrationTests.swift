import Foundation
import Testing
@testable import MacadeKit

/// Opt-in: `MACADE_INTEGRATION=1 MACADE_MANIFEST=<file://…/engine-manifest.json> swift test --filter Integration`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACADE_INTEGRATION"] == "1")) struct IntegrationTests {
    @Test func installsTheRealEngineAndWineRuns() async throws {
        let manifestURL = try #require(ProcessInfo.processInfo.environment["MACADE_MANIFEST"].flatMap(URL.init(string:)))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macade-int-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = EngineManager(paths: Paths(home: home))
        let manifest = try await manager.fetchManifest(from: manifestURL)
        let entry = try #require(manifest.latest)
        let engine = try await manager.install(entry)
        let r = try await ProcessRunner.run(engine.wine, ["--version"], environment: ["HOME": NSHomeDirectory()])
        #expect(r.succeeded)
        #expect(r.output.contains("wine-11"))
        #expect(FileManager.default.fileExists(atPath: engine.steamWebHelperWrapper.path))
    }
}
