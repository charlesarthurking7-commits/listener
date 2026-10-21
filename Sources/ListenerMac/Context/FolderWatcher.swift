import Foundation

/// Calls back when files are added to, removed from or saved into a folder. Editors
/// save by writing a new file and renaming it over the old one, which changes the
/// folder, so an edit in TextEdit shows up too.
@MainActor
final class FolderWatcher {
    private var source: (any DispatchSourceFileSystemObject)?

    func watch(_ folder: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated(onChange)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
