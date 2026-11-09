import Foundation
import Testing
@testable import MacadeKit

@Suite struct EpicLibraryTests {
    /// The traceback from the 2026-11-09 report of an account with 1,059 items.
    let timeout = """
        [cli] INFO: Getting game list... (this may take a while)
        requests.exceptions.ReadTimeout: HTTPSConnectionPool(host='launcher-public-service-prod06.ol.epicgames.com', port=443): Read timed out. (read timeout=10)
        [PYI-22320:ERROR] Failed to execute script 'cli' due to unhandled exception!
        """

    @Test func aTimeoutIsNamedAsOne() {
        let message = EpicProvider.failureSummary(fromLog: timeout)
        #expect(message.contains("took too long"))
        #expect(!message.contains("epicgames.com"))
    }

    @Test func otherFailuresShowOnlyTheLastErrorLineCutShort() {
        let long = "ValueError: " + String(repeating: "x", count: 400)
        let message = EpicProvider.failureSummary(fromLog: "[cli] INFO: Logging in...\nTraceback\n\(long)\n[PYI-1:ERROR] Failed\n")
        #expect(message.hasPrefix("Couldn't read your Epic library. ValueError: xxx"))
        #expect(message.count < 220)
        #expect(!message.contains("Logging in"))
    }

    @Test func noErrorLineKeepsTheOldMessage() {
        #expect(EpicProvider.failureSummary(fromLog: "") == "Couldn't read your Epic library.")
    }

    @Test func theApiTimeoutIsLongerThanLegendarysDefault() {
        #expect(EpicProvider.apiTimeout > 10)
    }
}

@Suite struct EpicLibraryRunTests {
    /// A stand-in for legendary that records its arguments and fails like a timed-out list.
    func provider(script: String) throws -> (EpicProvider, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("epic-" + UUID().uuidString)
        let paths = Paths(home: home)
        try paths.createDirectories()
        let tool = paths.tools.appendingPathComponent("legendary")
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (EpicProvider(paths: paths), home)
    }

    @Test func aTimedOutListIsRetriedOnceLoggedAndExplained() async throws {
        let (epic, home) = try provider(script: """
            #!/bin/sh
            echo "$@" >> "$0.calls"
            echo "requests.exceptions.ReadTimeout: Read timed out. (read timeout=10)" >&2
            exit 1
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        await #expect(throws: EpicError.self) { _ = try await epic.libraryList() }
        let calls = try String(contentsOf: epic.legendary.appendingPathExtension("calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 2)
        #expect(calls.hasPrefix("--api-timeout 60 list --platform Windows --json"))
        let logs = epic.runner.logs.logs(for: "epic")
        #expect(logs.count == 2)
        let text = try String(contentsOf: logs[0], encoding: .utf8)
        #expect(text.contains("[MaPC] Launch") && text.contains("ReadTimeout") && text.contains("[MaPC] Exit"))
    }

    @Test func aListThatWorksOnTheRetrySucceeds() async throws {
        let (epic, home) = try provider(script: """
            #!/bin/sh
            if [ -e "$0.once" ]; then echo '[]'; exit 0; fi
            touch "$0.once"; echo "Read timed out" >&2; exit 1
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(String(decoding: try await epic.libraryList(), as: UTF8.self).contains("[]"))
    }
}
