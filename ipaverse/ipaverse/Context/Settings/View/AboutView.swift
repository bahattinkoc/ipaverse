//
//  AboutView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 20.06.2026.
//

import SwiftUI

// MARK: - AboutView

struct AboutView: View {
    @StateObject private var updateChecker = UpdateChecker()

    private static let repoURL = URL(string: "https://github.com/bahattinkoc/ipaverse")!

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            VStack(spacing: 4) {
                Text(Bundle.main.appName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text("Version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

            Text("Download, re-sign, and sideload iOS apps —\nwithout Xcode or Terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal)

            updateSection
                .padding(.top, 20)

            Link(destination: Self.repoURL) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("View on GitHub")
                }
                .font(.callout.weight(.medium))
            }
            .padding(.top, 14)

            Spacer(minLength: 16)

            Text("© 2026 Bahattin Koç")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Update Section

    @ViewBuilder
    private var updateSection: some View {
        switch updateChecker.state {
        case .idle:
            checkButton

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("You're up to date")
            }
            .font(.callout)

        case let .updateAvailable(version, url):
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Version \(version) is available")
                }
                .font(.callout)

                Link(destination: url) {
                    Text("Download Update")
                }
                .buttonStyle(.borderedProminent)
            }

        case let .failed(message):
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                checkButton
            }
        }
    }

    private var checkButton: some View {
        Button {
            Task { await updateChecker.check() }
        } label: {
            Text("Check for Updates")
        }
        .controlSize(.large)
    }
}

// MARK: - UpdateChecker

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, url: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let repo = "bahattinkoc/ipaverse"

    func check() async {
        state = .checking

        guard let endpoint = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            state = .failed("Invalid update URL")
            return
        }

        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                state = .failed("No response from server")
                return
            }

            guard http.statusCode == 200 else {
                // 404 = repository has no published releases yet.
                state = http.statusCode == 404
                    ? .failed("No releases published yet")
                    : .failed("Couldn't check (HTTP \(http.statusCode))")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = normalize(release.tagName)
            let current = normalize(Bundle.main.shortVersion)

            if isVersion(latest, newerThan: current), let url = URL(string: release.htmlURL) {
                state = .updateAvailable(version: latest, url: url)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed("Network error — check your connection")
        }
    }

    /// Strips a leading "v" so "v2.1" and "2.1" compare equal.
    private func normalize(_ version: String) -> String {
        var v = version.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return v
    }

    /// Numeric, component-wise semantic comparison ("2.10" > "2.9").
    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

// MARK: - Bundle Info

extension Bundle {
    var appName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "ipaverse"
    }

    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var buildNumber: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
