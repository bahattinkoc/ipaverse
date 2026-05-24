//
//  IPAPatcher.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 24.05.2026.
//

import Foundation

struct SinfData {
    let id: Int64
    let data: Data
}

enum IPAPatchError: LocalizedError {
    case bundleNameNotFound
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundleNameNotFound: "Could not find app bundle in IPA"
        case .zipFailed(let msg): "Failed to patch IPA: \(msg)"
        }
    }
}

struct IPAPatcher {

    func applyPatches(ipaPath: String, sinfs: [SinfData], email: String) throws {
        guard !sinfs.isEmpty else {
            print("🔐 [IPAPatcher] no sinfs — skipping")
            return
        }

        print("🔐 [IPAPatcher] starting for: \(ipaPath)")

        // Step 1: List entries
        let entries: [String]
        do {
            entries = try listEntries(ipaPath: ipaPath)
            print("🔐 [IPAPatcher] entries count: \(entries.count)")
            if entries.isEmpty {
                print("🔐 [IPAPatcher] ⚠️ no entries — unzip -Z1 may have failed or IPA is invalid")
            } else {
                print("🔐 [IPAPatcher] first 5 entries: \(Array(entries.prefix(5)))")
            }
        } catch {
            print("🔐 [IPAPatcher] ❌ listEntries failed: \(error)")
            throw error
        }

        // Step 2: Bundle name
        let bundleName: String
        do {
            bundleName = try extractBundleName(from: entries)
            print("🔐 [IPAPatcher] bundle name: \(bundleName)")
        } catch {
            print("🔐 [IPAPatcher] ❌ extractBundleName failed. entries sample: \(Array(entries.prefix(10)))")
            throw error
        }

        // Step 3: Temp work dir
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        var filesToAdd: [String] = []

        // Step 4: Sinf placement via Manifest.plist
        let manifestEntry = entries.first { $0.hasSuffix(".app/SC_Info/Manifest.plist") }
        print("🔐 [IPAPatcher] manifest entry: \(manifestEntry ?? "not found")")
        var sinfInjected = false

        if let manifestEntryName = manifestEntry {
            let manifestData: Data
            do {
                manifestData = try readEntry(ipaPath: ipaPath, entryName: manifestEntryName)
                print("🔐 [IPAPatcher] manifest data size: \(manifestData.count) bytes")
            } catch {
                print("🔐 [IPAPatcher] ❌ readEntry(manifest) failed: \(error)")
                throw error
            }

            if let sinfPaths = parseManifestSinfPaths(data: manifestData) {
                print("🔐 [IPAPatcher] SinfPaths: \(sinfPaths)")
                for (sinf, path) in zip(sinfs, sinfPaths) {
                    let zipPath = "Payload/\(bundleName).app/\(path)"
                    let fileURL = workDir.appendingPathComponent(zipPath)
                    do {
                        try FileManager.default.createDirectory(
                            at: fileURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try sinf.data.write(to: fileURL)
                        filesToAdd.append(zipPath)
                        print("🔐 [IPAPatcher] wrote sinf to: \(zipPath) (\(sinf.data.count) bytes)")
                    } catch {
                        print("🔐 [IPAPatcher] ❌ failed to write sinf at \(zipPath): \(error)")
                        throw error
                    }
                }
                sinfInjected = true
            } else {
                print("🔐 [IPAPatcher] manifest has no SinfPaths — falling back to Info.plist")
            }
        }

        // Step 5: Fallback via Info.plist
        if !sinfInjected, let firstSinf = sinfs.first {
            let infoEntry = entries.first {
                $0.contains(".app/Info.plist") && !$0.contains("/Watch/")
            }
            print("🔐 [IPAPatcher] info.plist entry: \(infoEntry ?? "not found")")

            if let infoEntryName = infoEntry {
                let infoData: Data
                do {
                    infoData = try readEntry(ipaPath: ipaPath, entryName: infoEntryName)
                    print("🔐 [IPAPatcher] info.plist data size: \(infoData.count) bytes")
                } catch {
                    print("🔐 [IPAPatcher] ❌ readEntry(info) failed: \(error)")
                    throw error
                }

                if let executable = parseInfoBundleExecutable(data: infoData) {
                    let zipPath = "Payload/\(bundleName).app/SC_Info/\(executable).sinf"
                    let fileURL = workDir.appendingPathComponent(zipPath)
                    do {
                        try FileManager.default.createDirectory(
                            at: fileURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try firstSinf.data.write(to: fileURL)
                        filesToAdd.append(zipPath)
                        print("🔐 [IPAPatcher] wrote sinf to: \(zipPath) (\(firstSinf.data.count) bytes)")
                    } catch {
                        print("🔐 [IPAPatcher] ❌ failed to write sinf at \(zipPath): \(error)")
                        throw error
                    }
                } else {
                    print("🔐 [IPAPatcher] ⚠️ CFBundleExecutable not found in Info.plist")
                }
            }
        }

        // Step 6: iTunesMetadata.plist
        let metadataURL = workDir.appendingPathComponent("iTunesMetadata.plist")
        do {
            let metadata: [String: Any] = ["apple-id": email, "userName": email]
            let metadataData = try PropertyListSerialization.data(
                fromPropertyList: metadata, format: .binary, options: 0
            )
            try metadataData.write(to: metadataURL)
            filesToAdd.append("iTunesMetadata.plist")
        } catch {
            print("🔐 [IPAPatcher] ❌ failed to write iTunesMetadata.plist: \(error)")
            throw error
        }

        // Step 7: zip -u
        print("🔐 [IPAPatcher] injecting \(filesToAdd.count) file(s): \(filesToAdd)")
        do {
            try updateZip(ipaPath: ipaPath, workDir: workDir.path, paths: filesToAdd)
            print("🔐 [IPAPatcher] ✅ patch complete")
        } catch {
            print("🔐 [IPAPatcher] ❌ updateZip failed: \(error)")
            throw error
        }
    }

    // MARK: - Zip operations

    private func listEntries(ipaPath: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", ipaPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Read pipes BEFORE waitUntilExit — avoids pipe-buffer deadlock on large IPAs
        let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if !stderr.isEmpty { print("🔐 [IPAPatcher] unzip -Z1 stderr: \(stderr)") }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func readEntry(ipaPath: String, entryName: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", ipaPath, entryName]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        // Read before wait to avoid deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private func updateZip(ipaPath: String, workDir: String, paths: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        process.arguments = ["-u", ipaPath] + paths
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe
        try process.run()
        // Read before wait to avoid deadlock
        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        print("🔐 [IPAPatcher] zip stdout: \(stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        if !stderr.isEmpty { print("🔐 [IPAPatcher] zip stderr: \(stderr)") }
        print("🔐 [IPAPatcher] zip exit code: \(process.terminationStatus)")

        // 0 = success, 12 = nothing to update (already up-to-date)
        guard process.terminationStatus == 0 || process.terminationStatus == 12 else {
            throw IPAPatchError.zipFailed("exit \(process.terminationStatus): \(stderr)")
        }
    }

    // MARK: - Parsing

    private func extractBundleName(from entries: [String]) throws -> String {
        for entry in entries where entry.contains(".app/Info.plist") && !entry.contains("/Watch/") {
            let components = entry.components(separatedBy: "/")
            if let appComponent = components.first(where: { $0.hasSuffix(".app") }) {
                return String(appComponent.dropLast(4))
            }
        }
        throw IPAPatchError.bundleNameNotFound
    }

    private func parseManifestSinfPaths(data: Data) -> [String]? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
              let paths = plist["SinfPaths"] as? [String],
              !paths.isEmpty else { return nil }
        return paths
    }

    private func parseInfoBundleExecutable(data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }
        return plist["CFBundleExecutable"] as? String
    }
}
