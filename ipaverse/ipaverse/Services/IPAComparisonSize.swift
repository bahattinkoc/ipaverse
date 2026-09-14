import Foundation

struct IPAComparisonFileSize: Codable, Identifiable, Equatable {
    var id: String { source }
    let source: String
    let before: Int64?
    let after: Int64?
    var delta: Int64 { (after ?? 0) - (before ?? 0) }
    var kind: String { before == nil ? "Added" : after == nil ? "Removed" : delta == 0 ? "Unchanged" : "Changed" }
    var swapped: Self { Self(source: source, before: after, after: before) }
    var signingArtifact: Bool {
        source.split(separator: "/").contains("_CodeSignature") || (source as NSString).lastPathComponent == "embedded.mobileprovision"
    }
    // Exclusive ownership: a nested framework is counted in its own component,
    // not also in the containing extension. Symlinks are excluded at inventory time.
    var component: String {
        let parts = source.split(separator: "/").dropLast()
        let extensions: Set<String> = ["framework", "appex", "bundle", "app", "xpc"]
        var prefix: [String] = []
        var owner = "."
        for part in parts {
            prefix.append(String(part))
            if extensions.contains((String(part) as NSString).pathExtension.lowercased()) { owner = prefix.joined(separator: "/") }
        }
        return owner
    }
}

struct IPAComparisonSizeGroup: Identifiable {
    let id: String
    let files: [IPAComparisonFileSize]
    var before: Int64 { files.reduce(0) { $0 + ($1.before ?? 0) } }
    var after: Int64 { files.reduce(0) { $0 + ($1.after ?? 0) } }
    var delta: Int64 { after - before }
    var growth: Int64 { files.reduce(0) { $0 + max(0, $1.delta) } }
    var reduction: Int64 { files.reduce(0) { $0 + min(0, $1.delta) } }
    var changedCount: Int { files.filter { $0.kind != "Unchanged" }.count }
    static func groups(_ files: [IPAComparisonFileSize]) -> [Self] {
        Dictionary(grouping: files, by: \.component).map { Self(id: $0.key, files: $0.value) }.sorted {
            if abs($0.delta) != abs($1.delta) { return abs($0.delta) > abs($1.delta) }
            return $0.id < $1.id
        }
    }
}

enum IPAComparisonSizeFormat {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func signed(_ value: Int64) -> String { (value > 0 ? "+" : "") + bytes(value) }
    static func exact(_ value: Int64) -> String { value.formatted() + " bytes" }
}
