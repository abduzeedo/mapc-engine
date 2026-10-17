import Foundation
import CoreServices

/// Watches a directory tree with FSEvents and calls `onChange` (debounced). No polling.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "macade.directory-watcher")
    private let onChange: @Sendable () -> Void

    /// Missing directories are fine: the watcher watches the nearest existing parent instead.
    public init(directory: URL, latency: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var watched = directory
        while !FileManager.default.fileExists(atPath: watched.path), watched.pathComponents.count > 1 {
            watched.deleteLastPathComponent()
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [watched.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
