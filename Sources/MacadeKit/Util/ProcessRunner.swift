import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
    public var succeeded: Bool { status == 0 }
}

public enum ProcessRunnerError: Error {
    case launchFailed(String)
}

/// Async wrapper around `Process`: streams output lines, supports cancellation.
public enum ProcessRunner {
    public enum Line: Sendable {
        case stdout(String)
        case stderr(String)
    }

    /// Runs to completion and returns combined output. Cancelling the task terminates the process.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        onLine: (@Sendable (Line) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = Collector()

        let attach: (Pipe, @escaping @Sendable (String) -> Line) -> Void = { pipe, wrap in
            let splitter = LineSplitter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                for line in splitter.feed(data) {
                    collector.append(line)
                    onLine?(wrap(line))
                }
            }
        }
        attach(out) { .stdout($0) }
        attach(err) { .stderr($0) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    // Drain whatever is left in the pipes.
                    for (pipe, wrap) in [(out, { Line.stdout($0) }), (err, { Line.stderr($0) })] {
                        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                        if let s = String(data: rest, encoding: .utf8), !s.isEmpty {
                            for line in s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                                collector.append(line); onLine?(wrap(line))
                            }
                        }
                    }
                    cont.resume(returning: ProcessResult(status: p.terminationStatus, output: collector.text))
                }
                do { try process.run() }
                catch { cont.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription)) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

/// Splits a byte stream into lines, keeping partial trailing data between reads.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }
}
