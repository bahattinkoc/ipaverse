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
        guard rename(staged.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
