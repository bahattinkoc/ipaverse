import Foundation
import CryptoKit

enum MacPackageExportError: LocalizedError {
    case unsupportedFormat, missingApplication, ambiguousApplication, invalidApplication, unsafeLink

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Choose .pkg, .app, or .zip for a macOS download."
        case .missingApplication: "The installer does not contain the requested application. Choose .pkg to keep the original installer."
        case .ambiguousApplication: "The installer contains multiple copies of this application. Choose .pkg to keep the original installer."
        case .invalidApplication: "The extracted application is incomplete or has invalid metadata. Choose .pkg to keep the original installer."
        case .unsafeLink: "The application contains a link outside its bundle and cannot be exported safely. Choose .pkg to keep the original installer."
        }
    }
}

enum MacPackageExport {
    /// Works only on a decrypted, verified staging file. pkgutil expands payloads;
    /// it does not run installer scripts, register receipts, or install the app.
    /// The final destination stays untouched until PackageDownload commits.
    static func prepare(_ staged: URL, format: MacDownloadType, bundleID: String?) throws -> String? {
        guard format != .pkg else { return nil }
        try Task.checkCancellation()
        guard let bundleID, !bundleID.isEmpty else { throw MacPackageExportError.missingApplication }
        let fm = FileManager.default
        let workspace = staged.deletingLastPathComponent().appendingPathComponent(".ipaverse-\(UUID().uuidString).export")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workspace) }
        let package = workspace.appendingPathComponent("Source.pkg")
        try fm.moveItem(at: staged, to: package)
        let expanded = workspace.appendingPathComponent("Expanded")
        _ = try ProcessRunner.run("/usr/sbin/pkgutil", ["--expand-full", package.path, expanded.path], timeout: 600)
        let app = try application(in: expanded, bundleID: bundleID)
        let info = try MacAppBundle.info(at: app)
        try MacAppBundle.validateContents(at: app)
        try Task.checkCancellation()
        switch format {
        case .pkg: break
        case .app:
            try fm.moveItem(at: app, to: staged)
        case .zip:
            _ = try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, staged.path], timeout: 600)
            _ = try ProcessRunner.run("/usr/bin/unzip", ["-tqq", staged.path], timeout: 600)
        }
        return info["CFBundleShortVersionString"] as? String
    }

    static func application(in directory: URL, bundleID: String) throws -> URL {
        let fm = FileManager.default
        var traversalError: Error?
        guard let entries = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                         errorHandler: { _, error in traversalError = error; return false }) else {
            throw MacPackageExportError.missingApplication
        }
        var matches: [URL] = []
        for case let url as URL in entries {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { entries.skipDescendants(); continue }
            guard values.isDirectory == true, url.pathExtension.lowercased() == "app" else { continue }
            // Helpers inside an application are part of that bundle, not candidates.
            entries.skipDescendants()
            guard let info = try? MacAppBundle.info(at: url), info["CFBundleIdentifier"] as? String == bundleID else { continue }
            matches.append(url)
        }
        if let traversalError { throw traversalError }
        guard !matches.isEmpty else { throw MacPackageExportError.missingApplication }
        guard matches.count == 1 else { throw MacPackageExportError.ambiguousApplication }
        return matches[0]
    }
}

enum MacAppBundle {
    static func info(at app: URL) throws -> [String: Any] {
        let root = app.standardizedFileURL.resolvingSymlinksInPath()
        let plist = app.appendingPathComponent("Contents/Info.plist").resolvingSymlinksInPath()
        guard plist.path.hasPrefix(root.path + "/"),
              let size = try plist.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              info["CFBundlePackageType"] as? String == "APPL",
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable != ".", executable != "..", !executable.contains("/"), !executable.contains("\\") else {
            throw MacPackageExportError.invalidApplication
        }
        let binary = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).resolvingSymlinksInPath()
        guard binary.path.hasPrefix(root.path + "/"),
              try binary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw MacPackageExportError.invalidApplication
        }
        return info
    }

    static func validateContents(at app: URL) throws {
        let root = app.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for url in try contents(at: app) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                guard !target.hasPrefix("/"), url.resolvingSymlinksInPath().path.hasPrefix(root) else {
                    throw MacPackageExportError.unsafeLink
                }
            } else if values.isDirectory != true && values.isRegularFile != true {
                throw MacPackageExportError.invalidApplication
            }
        }
    }

    static func size(at app: URL) throws -> Int64 {
        try contents(at: app).reduce(0) { total, url in
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            return total + (values.isRegularFile == true && values.isSymbolicLink != true ? Int64(values.fileSize ?? 0) : 0)
        }
    }

    /// Deterministic bundle identity: paths, types, modes, file bytes, and symlink
    /// targets. Never follow a link or hash a file outside the bundle.
    static func hash(at app: URL) throws -> String {
        let app = app.standardizedFileURL.resolvingSymlinksInPath()
        let root = app.path + "/"
        var hash = SHA256()
        func field(_ text: String) {
            let bytes = Data(text.utf8)
            hash.update(data: Data("\(bytes.count):".utf8))
            hash.update(data: bytes)
        }
        for url in try contents(at: app).sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            field(String(url.standardizedFileURL.path.dropFirst(root.count)))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            field(String(describing: attributes[.posixPermissions] ?? 0))
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                field("link"); field(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory: field("directory")
            case .typeRegular:
                field("file"); field(String(describing: attributes[.size] ?? 0))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: data)
                }
            default: throw MacPackageExportError.invalidApplication
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func contents(at app: URL) throws -> [URL] {
        var traversalError: Error?
        guard let entries = FileManager.default.enumerator(at: app,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            errorHandler: { _, error in traversalError = error; return false }) else {
            throw MacPackageExportError.invalidApplication
        }
        var urls: [URL] = []
        for case let url as URL in entries {
            try Task.checkCancellation()
            urls.append(url)
        }
        if let traversalError { throw traversalError }
        return urls
    }
}
