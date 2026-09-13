import Foundation
import CoreServices

/// Wraps FSEvents to watch one document's containing directory (FSEvents
/// itself is directory-granular; watching the parent also survives editors
/// that save via temp-file-then-rename). Only ever running while a document
/// is in Modo Libre — Modo App turns it off entirely so the app never reacts
/// to its own writes (spec §05, ADR-001).
public final class ListoFileWatcher {
    public let fileURL: URL
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "listo.filewatcher")

    public init(fileURL: URL, onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
    }

    public var isRunning: Bool { stream != nil }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let watchedDir = fileURL.deletingLastPathComponent().path
        let pathsToWatch = [watchedDir] as CFArray

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            Unmanaged<ListoFileWatcher>.fromOpaque(clientInfo).takeUnretainedValue().onChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, // seconds of latency — coalesces rapid keystroke-driven saves
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
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
