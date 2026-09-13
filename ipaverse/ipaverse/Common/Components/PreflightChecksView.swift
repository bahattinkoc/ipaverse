import SwiftUI

struct PreflightChecksView: View {
    let checks: [PreflightCheck]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.status == .passed ? "checkmark.circle.fill" : check.status == .blocked ? "xmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(check.status == .passed ? .green : check.status == .blocked ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.caption.weight(.semibold))
                        Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
