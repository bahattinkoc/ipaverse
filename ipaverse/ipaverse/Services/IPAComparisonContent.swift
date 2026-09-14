import Foundation
import ImageIO
import UniformTypeIdentifiers

extension IPAComparison {
    /// Inspect content as well as extensions: bundles often use .config, .dat or no suffix for JSON/plists.
    static func resource(_ file: URL, source: String, size: Int, budget: inout Int, into result: inout Snapshot) throws {
        if file.pathExtension.lowercased() == "car" {
            try result.capture("Asset catalogs", source) { snapshot in
                try IPAComparisonAssets.read(file, source: source, budget: &budget, into: &snapshot)
            }
            return
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 4096) ?? Data()
        let ext = file.pathExtension.lowercased()
        let prefixText = (0...min(3, prefix.count)).lazy.compactMap { decodedText(Data(prefix.dropLast($0))) }.first
        let textPrefix = prefixText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isPlist = ["plist", "strings", "stringsdict", "entitlements"].contains(ext) || prefix.starts(with: Data("bplist00".utf8)) || textPrefix.contains("<plist")
        let isJSON = ext == "json" || textPrefix.hasPrefix("{") || textPrefix.hasPrefix("[")
        let knownText = ["txt", "xml", "html", "htm", "css", "js", "mjs", "yaml", "yml", "csv", "ini", "cfg", "conf", "config", "properties", "env", "md", "sql", "graphql", "map", "svg", "pem", "crt", "cer"].contains(ext)
        let imageTypes = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "ico", "icns"]
        if imageTypes.contains(ext) {
            try result.capture("Resources", source) { snapshot in
                try imageResource(file, source: source, budget: &budget, into: &snapshot)
            }
            return
        }
        guard isPlist || isJSON || knownText || prefixText != nil else {
            result.status("Resources", source, "Unavailable", "No structured decoder; byte differences are available for changed files")
            return
        }
        let limit = isPlist || isJSON ? 8 * 1024 * 1024 : 512 * 1024
        guard size <= limit, size <= budget else {
            result.status("Resources", source, "Skipped", "Content limit: \(limit) bytes per file / 32 MiB total")
            return
        }
        budget -= size
        let data = try Data(contentsOf: file)
        if isPlist {
            try result.capture("Resources", source) { snapshot in
                let value = try PropertyListSerialization.propertyList(from: data, format: nil)
                flatten(value, category: "Resources", source: source, into: &snapshot)
            }
        } else if isJSON, let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            flatten(value, category: "Resources", source: source, into: &result)
            result.status("Resources", source)
        } else if ext == "json" {
            result.status("Resources", source, "Failed", "Invalid JSON; raw byte differences are available")
        } else if let text = decodedText(data) {
            result.add("Resources", source, "Text", text, type: "text")
            result.status("Resources", source)
        } else { result.status("Resources", source, "Unavailable", "Unsupported text encoding; byte differences are available") }
    }

    static func decodedText(_ data: Data) -> String? {
        // Decode BOM-marked UTF-16/32; don't mistake arbitrary binary pairs for UTF-16 text.
        let encoding: String.Encoding
        if data.starts(with: [0xff, 0xfe, 0, 0]) || data.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32 }
        else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { encoding = .utf16 }
        else { encoding = .utf8 }
        guard let text = String(data: data, encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else { return nil }
        return text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
    }

    private static func imageResource(_ file: URL, source: String, budget: inout Int, into result: inout Snapshot) throws {
        guard let image = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] else {
            throw IPAComparisonError.invalidData("Image decoder could not read this resource")
        }
        flatten(properties, category: "Resources", source: source, prefix: "/Image", into: &result)
        result.add("Resources", source, "/Image/Frames", String(CGImageSourceGetCount(image)), type: "number")
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? 0
        guard width * height <= 64_000_000, budget >= 1024 * 1024 else {
            result.status("Resources", source, "Partial", "Image metadata available; preview exceeds decode/budget limit")
            return
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else {
            result.status("Resources", source, "Partial", "Image metadata available; preview decoding failed")
            return
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            result.status("Resources", source, "Partial", "Image metadata available; preview encoding failed")
            return
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        if CGImageDestinationFinalize(destination), data.length <= budget {
            result.imagePreviews[source] = data as Data
            budget -= data.length
        } else {
            result.status("Resources", source, "Partial", "Image metadata available; preview encoding/budget limit")
        }
    }

    /// Positional byte changes for formats without a semantic decoder (and executable code).
    /// Reads only changed files, retains differing blocks, and never treats a sample as a full diff.
    static func compareOpaqueFiles(_ a: URL, _ b: URL, left: inout Snapshot, right: inout Snapshot) throws {
        let filesA = Dictionary(uniqueKeysWithValues: left.values.values.filter { $0.category == "Files" && $0.path == "Content" }.map { ($0.source, $0.text) })
        let filesB = Dictionary(uniqueKeysWithValues: right.values.values.filter { $0.category == "Files" && $0.path == "Content" }.map { ($0.source, $0.text) })
        var budget = 256 * 1024 * 1024, blockBudget = 2048
        for source in Set(filesA.keys).union(filesB.keys).sorted() where filesA[source] != filesB[source] {
            try Task.checkCancellation()
            // Catalogs have an asset-level visual view, including explicit decode failures.
            if (source as NSString).pathExtension.lowercased() == "car" { continue }
            let signing = source.split(separator: "/").contains("_CodeSignature") || source.hasSuffix("embedded.mobileprovision")
            let readableA = left.coverage["Resources|" + source]?.state == "Complete" || left.coverage["Info.plist|" + source]?.state == "Complete"
            let readableB = right.coverage["Resources|" + source]?.state == "Complete" || right.coverage["Info.plist|" + source]?.state == "Complete"
            if (readableA || filesA[source] == nil) && (readableB || filesB[source] == nil) { continue }
            guard budget > 0, blockBudget > 0 else {
                for side in [0, 1] {
                    if side == 0 { left.status("Binary content", source, "Skipped", "Byte diff budget exhausted") }
                    else { right.status("Binary content", source, "Skipped", "Byte diff budget exhausted") }
                }
                continue
            }
            do {
                let first = filesA[source] == nil ? nil : try FileHandle(forReadingFrom: a.appendingPathComponent(source))
                defer { try? first?.close() }
                let second = filesB[source] == nil ? nil : try FileHandle(forReadingFrom: b.appendingPathComponent(source))
                defer { try? second?.close() }
                var offset = 0, blocks = 0, reachedEOF = false
                let maxRead = min(budget, 64 * 1024 * 1024), maxBlocks = min(blockBudget, 64)
                while offset < maxRead, blocks < maxBlocks {
                    try Task.checkCancellation()
                    let size = min(64 * 1024, maxRead - offset)
                    let da = try first?.read(upToCount: size) ?? Data(), db = try second?.read(upToCount: size) ?? Data()
                    if da.isEmpty && db.isEmpty { reachedEOF = true; break }
                    let count = max(da.count, db.count)
                    for index in stride(from: 0, to: count, by: 16) {
                        let aa = index < da.count ? da.subdata(in: index..<min(index + 16, da.count)) : Data()
                        let bb = index < db.count ? db.subdata(in: index..<min(index + 16, db.count)) : Data()
                        guard aa != bb else { continue }
                        let path = String(format: "Bytes @ 0x%08llX", Int64(offset + index))
                        if !aa.isEmpty { left.add("Binary content", source, path, hex(aa), type: "hex bytes", signing: signing) }
                        if !bb.isEmpty { right.add("Binary content", source, path, hex(bb), type: "hex bytes", signing: signing) }
                        blocks += 1
                        if blocks >= maxBlocks { break }
                    }
                    offset += count
                }
                budget -= offset
                blockBudget -= blocks
                let detail = reachedEOF ? "\(blocks) changed 16-byte blocks" : "Sample: first \(blocks) changed 16-byte blocks; scan stopped within \(offset) bytes"
                left.status("Binary content", source, "Complete", detail)
                right.status("Binary content", source, "Complete", detail)
            } catch is CancellationError { throw CancellationError() }
            catch {
                left.status("Binary content", source, "Failed", error.localizedDescription)
                right.status("Binary content", source, "Failed", error.localizedDescription)
            }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ") + "  |" +
            data.map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined() + "|"
    }
}

/// Shared by the file list and detail pane so selecting a hash row always leads to its content changes.
enum IPAComparisonPresentation {
    static func includingFileContent(_ rows: [IPAComparisonChange], index: [String: [IPAComparisonChange]]) -> [IPAComparisonChange] {
        var result = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for file in rows where file.category == "Files" {
            for child in index[file.source] ?? [] { result[child.id] = child }
        }
        return result.values.sorted { $0.id < $1.id }
    }

    static func contentIndex(_ report: IPAComparisonReport) -> [String: [IPAComparisonChange]] {
        let paths = Set(report.rows.filter { $0.category == "Files" }.map(\.source))
        var result: [String: [IPAComparisonChange]] = [:]
        for row in report.rows where row.category != "Files" && row.category != "Components" {
            var source = row.source
            if !paths.contains(source), source.hasSuffix(" / Methods") { source = String(source.dropLast(" / Methods".count)) }
            if !paths.contains(source), let range = source.range(of: " [", options: .backwards), source.hasSuffix("]") { source = String(source[..<range.lowerBound]) }
            result[source, default: []].append(row)
        }
        return result.mapValues { $0.sorted { rank($0) == rank($1) ? $0.path < $1.path : rank($0) < rank($1) } }
    }

    static func rank(_ row: IPAComparisonChange) -> Int {
        if row.source == "Info.plist", row.category != "Files" { return 0 }
        return ["Info.plist", "Entitlements", "Resources", "Asset catalogs", "Mach-O", "Signing", "Components", "Classes", "Symbols", "Endpoints", "Strings", "Security findings", "Binary content", "Files"].firstIndex(of: row.category).map { $0 + 1 } ?? 99
    }

    static func fileValue(_ file: IPAComparisonChange, content: [IPAComparisonChange], before: Bool) -> String {
        let raw = before ? file.before : file.after
        guard raw != nil else { return "—" }
        let changes = content.filter { $0.kind != "Unchanged" && $0.kind != "Not compared" }
        if !changes.isEmpty {
            return changes.prefix(3).map { row in
                if row.valueType == "text" {
                    return "Text: " + ComparisonTextDiff.preview(before: row.before, after: row.after, beforeSide: before)
                }
                let value = before ? row.before : row.after
                return "\(row.path): \(value.map { $0.isEmpty ? "\"\"" : $0 } ?? "—")"
            }.joined(separator: "\n")
        }
        if content.contains(where: { $0.kind == "Not compared" }) { return "Content analysis incomplete" }
        if !content.isEmpty { return "\(content.count) parsed values unchanged" }
        return raw?.components(separatedBy: " · SHA-256").first ?? "Content available in details"
    }
}
