import Foundation

extension IPAComparison {
    static func tool(_ executable: String, _ arguments: [String], limit: Int = 16 * 1024 * 1024) throws -> String {
        let output = try ProcessRunner.run(executable, arguments, timeout: 60, maxOutputBytes: limit).output
        return String(decoding: output, as: UTF8.self)
    }

    static func binaryMetadata(_ file: URL, source: String, deep: Bool, into result: inout Snapshot) throws {
        var architectures: [String] = []
        var encryptedArchitectures: Set<String> = []
        try result.capture("Mach-O", source) { snapshot in
            architectures = try tool("/usr/bin/lipo", ["-archs", file.path]).split(whereSeparator: \.isWhitespace).map(String.init)
            guard !architectures.isEmpty else { throw IPAComparisonError.invalidData("No Mach-O architecture found") }
            for architecture in architectures {
                try Task.checkCancellation()
                snapshot.add("Mach-O", source, "Architectures/" + architecture, architecture)
                let commands = try tool("/usr/bin/otool", ["-arch", architecture, "-l", file.path])
                let parsed = parseLoadCommands(commands)
                guard !parsed.isEmpty else { throw IPAComparisonError.invalidData("No readable load commands for " + architecture) }
                for (path, text) in parsed {
                    snapshot.add("Mach-O", source, architecture + "/" + path, text, signing: path.hasPrefix("LC_CODE_SIGNATURE/"), uuid: path.hasPrefix("LC_UUID/"))
                    if path.contains("LC_ENCRYPTION_INFO"), path.hasSuffix("/cryptid"), text != "0" { encryptedArchitectures.insert(architecture) }
                }
                let headers = try tool("/usr/bin/otool", ["-arch", architecture, "-hv", file.path])
                let lines = headers.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasSuffix(":") }
                snapshot.add("Mach-O", source, architecture + "/Header", lines.joined(separator: "\n"), type: "text")
            }
            snapshot.add("Mach-O", source, "Encryption", encryptedArchitectures.isEmpty ? "Unencrypted" : "Encrypted")
        }
        guard deep else { return }
        guard result.coverage["Mach-O|" + source]?.state == "Complete" else {
            for category in deepCategories { result.status(category, source, "Failed", "Mach-O metadata unavailable") }
            return
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 512 * 1024 * 1024 else {
            for category in deepCategories { result.status(category, source, "Skipped", "Binary exceeds 512 MiB") }
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ipaverse-slices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        for architecture in architectures {
            try Task.checkCancellation()
            let sliceSource = source + " [" + architecture + "]"
            let slice: URL
            if architectures.count == 1 { slice = file }
            else {
                slice = work.appendingPathComponent(architecture)
                do { _ = try tool("/usr/bin/lipo", [file.path, "-thin", architecture, "-output", slice.path]) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    for category in deepCategories { result.status(category, sliceSource, "Failed", error.localizedDescription) }
                    continue
                }
            }
            try result.capture("Symbols", sliceSource) { snapshot in
                for (name, args) in [("Imported", ["-j", "-u"]), ("Exported", ["-j", "-g", "-U"])] {
                    let output = try tool("/usr/bin/nm", args + [slice.path])
                    let symbols = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    guard symbols.count <= 100_000 else { throw IPAComparisonError.invalidData("Symbol inventory exceeds 100,000 entries") }
                    for symbol in symbols { snapshot.add("Symbols", sliceSource, name + "/" + escaped(symbol), symbol, type: "symbol") }
                }
            }
            if encryptedArchitectures.contains(architecture) {
                for category in ["Classes", "Strings", "Endpoints"] { result.status(category, sliceSource, "Encrypted", "cryptid != 0") }
                continue
            }
            try result.capture("Classes", sliceSource) { snapshot in
                // Selector extraction in ClassDumper supports thin, little-endian arm64 only.
                guard architecture == "arm64" || architecture == "arm64e" else {
                    throw IPAComparisonError.invalidData("Class metadata parser supports arm64 / arm64e")
                }
                let dump = try ClassDumper.comparisonDump(binary: slice)
                for cls in dump.classes {
                    snapshot.add("Classes", sliceSource, "Classes/" + escaped(cls.rawName), "instance methods: \(cls.instanceMethodCount)\nclass methods: \(cls.classMethodCount)", type: "class")
                }
                for selector in Set(dump.allSelectors) { snapshot.add("Classes", sliceSource, "Selectors/" + escaped(selector), selector, type: "selector") }
            }
            let methodSource = sliceSource + " / Methods"
            if let r2 = ExternalToolManager.locateBinary("r2") {
                try result.capture("Classes", methodSource) { snapshot in
                    let text = try tool(r2, ["-q", "-c", "icj", slice.path])
                    guard let classes = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
                        throw IPAComparisonError.invalidData("Invalid r2 class metadata")
                    }
                    for cls in classes {
                        guard let name = cls["classname"] as? String, let methods = cls["methods"] as? [[String: Any]] else { continue }
                        for method in methods {
                            guard let nameOfMethod = method["name"] as? String, !nameOfMethod.isEmpty,
                                  !nameOfMethod.hasPrefix("func."), Int(nameOfMethod) == nil else { continue }
                            snapshot.add("Classes", methodSource, escaped(name) + "/" + escaped(nameOfMethod), nameOfMethod, type: "method")
                        }
                    }
                }
            } else { result.status("Classes", methodSource, "Unavailable", "r2 is not installed") }
            do {
                let text = try tool("/usr/bin/strings", ["-a", "-n", "6", slice.path])
                try stringInventory(text, source: sliceSource, into: &result)
            } catch is CancellationError { throw CancellationError() }
            catch {
                for category in ["Strings", "Endpoints"] { result.status(category, sliceSource, "Failed", error.localizedDescription) }
            }
        }
    }

    // Key load commands by their identity, not their index in the load-command array.
    // A newly inserted dylib must not make every following command look changed.
    static func parseLoadCommands(_ text: String) -> [String: String] {
        let blocks = text.components(separatedBy: "Load command ").dropFirst()
        var values: [String: String] = [:]
        var occurrences: [String: Int] = [:]
        for block in blocks {
            let lines = block.components(separatedBy: .newlines).dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let commandLine = lines.first(where: { $0.hasPrefix("cmd LC_") }) else { continue }
            let command = String(commandLine.dropFirst(4))
            let identity = lines.first(where: { $0.hasPrefix("name ") || $0.hasPrefix("path ") || $0.hasPrefix("segname ") })
                .map { line in line.components(separatedBy: " (offset")[0].split(maxSplits: 1, whereSeparator: \.isWhitespace).dropFirst().joined(separator: " ") } ?? ""
            let base = command + (identity.isEmpty ? "" : "/" + escaped(identity))
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let prefix = base + (occurrence == 0 ? "" : "/[\(occurrence)]")
            var section = ""
            var fieldOccurrences: [String: Int] = [:]
            for line in lines where !line.hasPrefix("cmd ") {
                if line == "Section" { section = "/Section"; continue }
                let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard fields.count == 2 else { continue }
                let field = String(fields[0]), value = String(fields[1])
                if field == "sectname" { section = "/Sections/" + escaped(value) }
                let key = prefix + section + "/" + field
                let count = fieldOccurrences[key, default: 0]
                fieldOccurrences[key] = count + 1
                values[key + (count == 0 ? "" : "/[\(count)]")] = value
            }
        }
        return values
    }

    static func stringInventory(_ text: String, source: String, into result: inout Snapshot) throws {
        try Task.checkCancellation()
        guard text.utf8.count <= 16 * 1024 * 1024 else { throw IPAComparisonError.invalidData("String input exceeds 16 MiB") }
        let strings = Set(text.components(separatedBy: .newlines).filter { !$0.isEmpty })
        guard strings.count <= 100_000, result.values.count + strings.count <= 500_000 else {
            throw IPAComparisonError.invalidData("String inventory limit exceeded (100,000 per source / 500,000 total rows)")
        }
        for string in strings { result.add("Strings", source, fingerprint(string), string, type: "string literal") }
        result.status("Strings", source)
        let regex = try NSRegularExpression(pattern: #"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>\"'\\]+|\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}\b"#)
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let endpoint = ns.substring(with: match.range)
            result.add("Endpoints", source, escaped(endpoint), endpoint, type: "static candidate")
            if let components = URLComponents(string: endpoint), let scheme = components.scheme {
                result.add("Endpoints", source, "Schemes/" + escaped(scheme.lowercased()), scheme.lowercased(), type: "scheme")
                if let host = components.host { result.add("Endpoints", source, "Hosts/" + escaped(host.lowercased()), host.lowercased(), type: "host") }
            }
        }
        result.status("Endpoints", source)
    }

    static func analyzeStrings(_ text: String, source: String, into result: inout Snapshot) throws {
        do { try stringInventory(text, source: source, into: &result) }
        catch is CancellationError { throw CancellationError() }
        catch {
            for category in ["Strings", "Endpoints"] { result.status(category, source, "Failed", error.localizedDescription) }
        }
    }
}
