import CoreServices
import Foundation

/// File-system events for a folder tree (FSEvents), coalesced by the stream's own latency, delivered on the main queue.
final class DiskWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(path: String, latency: TimeInterval = 0.15, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, watcherPointer, _, _, _, _ in
            guard let watcherPointer else { return }
            Unmanaged<DiskWatcher>.fromOpaque(watcherPointer).takeUnretainedValue().onChange()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
