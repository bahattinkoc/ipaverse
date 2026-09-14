import Foundation

enum ComparisonTextDiff {
    static func contextLines(before: String?, after: String?, context: Int = 3) -> [String] {
        let lines = render(before: before, after: after).components(separatedBy: "\n")
        let changes = lines.indices.filter { lines[$0].hasPrefix("+ ") || lines[$0].hasPrefix("− ") }
        guard !changes.isEmpty else { return lines }
        var included = Set<Int>()
        for index in changes {
            for neighbor in max(0, index - context)...min(lines.count - 1, index + context) { included.insert(neighbor) }
        }
        var result: [String] = [], previous = -1
        for index in included.sorted() {
            if index > previous + 1 { result.append("… \(index - previous - 1) unchanged lines") }
            result.append(lines[index])
            previous = index
        }
        if previous < lines.count - 1 { result.append("… \(lines.count - previous - 1) unchanged lines") }
        return result
    }

    static func preview(before: String?, after: String?, beforeSide: Bool) -> String {
        let prefix = beforeSide ? "− " : "+ "
        let changed = contextLines(before: before, after: after, context: 0).filter { $0.hasPrefix(prefix) }
        if !changed.isEmpty { return changed.prefix(3).map { String($0.dropFirst(2)) }.joined(separator: "\n") }
        guard let value = beforeSide ? before : after else { return "—" }
        if before == after { return String(value.prefix(160)) }
        // Even when a large replacement exceeds the line-diff budget, show its actual values.
        let a = before?.components(separatedBy: "\n") ?? [], b = after?.components(separatedBy: "\n") ?? []
        var common = 0
        while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        let lines = beforeSide ? a : b
        return common < lines.count ? lines.dropFirst(common).prefix(3).joined(separator: "\n") : "—"
    }

    static func render(before: String?, after: String?) -> String {
        let a = before?.components(separatedBy: "\n") ?? [], b = after?.components(separatedBy: "\n") ?? []
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        let middleA = Array(a[prefix..<(a.count - suffix)]), middleB = Array(b[prefix..<(b.count - suffix)])
        // Bound CollectionDifference's worst-case work for large unrelated resources.
        guard middleA.count + middleB.count <= 4000, middleA.reduce(0, { $0 + $1.utf8.count }) + middleB.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1024 else {
            return "Line diff limit exceeded. Use A / B or export the report."
        }
        let delta = middleB.difference(from: middleA)
        var removed: Set<Int> = [], inserted: Set<Int> = []
        for change in delta {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset + prefix)
            case .insert(let offset, _, _): inserted.insert(offset + prefix)
            }
        }
        var lines: [String] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { lines.append("− " + a[i]); i += 1 }
            else if j < b.count, inserted.contains(j) { lines.append("+ " + b[j]); j += 1 }
            else if i < a.count, j < b.count { lines.append("  " + a[i]); i += 1; j += 1 }
            else if i < a.count { lines.append("− " + a[i]); i += 1 }
            else { lines.append("+ " + b[j]); j += 1 }
        }
        return lines.joined(separator: "\n")
    }
}
