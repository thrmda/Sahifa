import CoreServices
import Foundation

/// Watches one source root *recursively*, so a file added or removed anywhere
/// in the tree shows up without waiting for the app to be reactivated.
///
/// FSEvents rather than a file descriptor per directory: one descriptor per
/// folder would cost hundreds of open files on a real notes tree, and could
/// only ever watch the folders already expanded. One stream covers the whole
/// subtree, including folders the user has not opened yet.
///
/// Events arrive coalesced on the main queue and name the *directories* that
/// changed, which is exactly the granularity the sidebar reloads at.
@MainActor
final class DirectoryWatcher {
    /// Directories whose contents changed.
    private let onChange: ([URL]) -> Void
    /// The root itself was deleted, renamed, or unmounted.
    private let onRootLost: () -> Void
    private var stream: FSEventStreamRef?

    init?(root: URL, onChange: @escaping ([URL]) -> Void, onRootLost: @escaping () -> Void) {
        self.onChange = onChange
        self.onRootLost = onRootLost

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        // Symlinks resolved so the paths FSEvents reports match what we
        // compare them against.
        let path = root.resolvingSymlinksInPath().path
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info)
                    .takeUnretainedValue()
                let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
                let changed = (list as? [String]) ?? []
                var directories: [URL] = []
                var rootLost = false
                for index in 0..<count {
                    let flag = flags[index]
                    if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                        rootLost = true
                    }
                    if index < changed.count {
                        directories.append(URL(fileURLWithPath: changed[index]))
                    }
                }
                // The stream was scheduled on the main queue below.
                MainActor.assumeIsolated {
                    if rootLost { watcher.onRootLost() }
                    if !directories.isEmpty { watcher.onChange(directories) }
                }
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // Coalesces a burst (a checkout, a sync) into one reload.
            0.3,
            UInt32(kFSEventStreamCreateFlagUseCFTypes
                   | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
