import Foundation
import CryptoKit

public enum EngineError: Error, LocalizedError, Equatable {
    case downloadFailed(String)
    case sizeMismatch
    case checksumMismatch
    case extractFailed
    case invalidEngine
    case sanityCheckFailed
    case inUse

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let m): "Couldn't download the game engine. \(m)"
        case .sizeMismatch, .checksumMismatch: "The downloaded engine is damaged (it failed its integrity check). Please try again."
        case .extractFailed: "Couldn't unpack the game engine."
        case .invalidEngine: "The downloaded engine isn't a valid MaPC engine."
        case .sanityCheckFailed: "The game engine was installed but didn't start. Make sure Rosetta is installed."
        case .inUse: "A game is running. Close it before changing the engine."
        }
    }
}

public enum EnginePhase: Sendable, Equatable { case downloading, verifying, extracting, finishing }

/// Downloads, verifies and installs engines (plan §4.2). Old engines are kept for rollback.
public struct EngineManager: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public func fetchManifest(from url: URL) async throws -> EngineManifest {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            // A missing list comes back as an HTML/text error page; say so instead of "unreadable".
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw EngineError.downloadFailed("The engine list isn't available (the server answered \(http.statusCode)).")
            }
            return try EngineManifest.decode(data)
        } catch let error as EngineError {
            throw error
        } catch let error as DecodingError {
            throw EngineError.downloadFailed("The engine list is unreadable. \(error.localizedDescription)")
        } catch {
            throw EngineError.downloadFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func install(_ entry: EngineManifest.Entry,
                        progress: @escaping @Sendable (EnginePhase, Double) -> Void = { _, _ in }) async throws -> Engine {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.engines, withIntermediateDirectories: true)
        let work = paths.engines.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 1. Download
        let archive = work.appendingPathComponent("engine.tar.xz")
        progress(.downloading, 0)
        try await download(entry.url, to: archive) { progress(.downloading, $0) }

        // 2. Verify
        progress(.verifying, 0)
        let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
        if entry.size > 0, size != entry.size { throw EngineError.sizeMismatch }
        guard try Self.sha256(of: archive) == entry.sha256.lowercased() else { throw EngineError.checksumMismatch }

        // 3. Extract
        progress(.extracting, 0)
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let tar = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xJf", archive.path, "-C", extracted.path])
        guard tar.succeeded else { throw EngineError.extractFailed }
        guard let candidate = Engine(directory: extracted), candidate.version == entry.version, candidate.isUsable else {
            throw EngineError.invalidEngine
        }

        // 4. Move into place atomically (an existing copy is replaced only after the new one is ready)
        progress(.finishing, 0)
        let destination = paths.engine(version: entry.version)
        let previous = work.appendingPathComponent("previous", isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: previous) }
        do { try fm.moveItem(at: extracted, to: destination) }
        catch {
            if fm.fileExists(atPath: previous.path) { try? fm.moveItem(at: previous, to: destination) }
            throw EngineError.extractFailed
        }
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", destination.path])

        // 5. Sanity check: the engine has to start.
        guard let engine = Engine(directory: destination),
              let check = try? await ProcessRunner.run(engine.wine, ["--version"], environment: ["HOME": NSHomeDirectory()]),
              check.succeeded else {
            try? fm.removeItem(at: destination)
            if fm.fileExists(atPath: previous.path) { try? fm.moveItem(at: previous, to: destination) }
            throw EngineError.sanityCheckFailed
        }
        return engine
    }

    public func remove(version: String) throws {
        try FileManager.default.removeItem(at: paths.engine(version: version))
    }

    // MARK: Helpers

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func download(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = ProgressDelegate(onProgress)
        do {
            let (tmp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw EngineError.downloadFailed("The server answered \(http.statusCode).")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch let error as EngineError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EngineError.downloadFailed((error as NSError).localizedDescription)
        }
    }
}

private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?
    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    // The async download API never calls the download-delegate callbacks, so watch the task's Progress instead.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] p, _ in
            onProgress(min(max(p.fractionCompleted, 0), 1))
        }
    }
}
