import Foundation
import Darwin

/// Stage beside the destination so committing is a single filesystem rename.
/// A failed download, validation, patch or cancellation never removes the old file.
enum AtomicFile {
    static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".ipaverse-\(UUID().uuidString).\(destination.pathExtension)")
    }

    static func commit(_ staged: URL, to destination: URL) throws {
        try Task.checkCancellation()
        guard staged.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        if try staged.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            // rename alone cannot replace a nonempty .app bundle. Swap names
            // atomically so a failed replacement never removes the old application.
            if renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
