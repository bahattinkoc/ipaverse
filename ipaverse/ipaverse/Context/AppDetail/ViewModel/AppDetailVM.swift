//
//  AppDetailVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 24.05.2026.
//

import SwiftUI
import AppKit
import SwiftData
import UniformTypeIdentifiers

@MainActor
final class AppDetailVM: ObservableObject {
    @Published var versionsState: VersionsLoadState = .loading
    @Published var loadingMessage = "Loading versions..."
    @Published var selectedVersionId: String?
    @Published var downloadState: DownloadState = .idle
    @Published var errorMessage: String?

    let app: AppStoreApp
    private let account: Account
    private var modelContext: ModelContext?
    private var loginViewModel: LoginVM?

    init(app: AppStoreApp, account: Account) {
        self.app = app
        self.account = account
    }

    func setup(modelContext: ModelContext, loginViewModel: LoginVM) {
        self.modelContext = modelContext
        self.loginViewModel = loginViewModel
    }

    func loadVersions() async {
        loadingMessage = "Loading versions..."
        versionsState = .loading
        let service = AppStoreService()
        do {
            let result = try await service.listVersions(app: app, account: account)
            applyVersions(result)
            await fetchDisplayNames(service: service)
        } catch LoginError.licenseRequired {
            await purchaseThenLoad(service: service)
        } catch {
            versionsState = .error(error.localizedDescription)
            selectedVersionId = nil
        }
    }

    private func purchaseThenLoad(service: AppStoreService) async {
        loadingMessage = "Purchasing app..."
        do {
            try await service.purchase(app: app, account: account)
        } catch LoginError.tokenExpired {
            await loginViewModel?.logout(withMessage: "Session expired. Please login again.")
            return
        } catch {
            let msg = error.localizedDescription
            if !msg.contains("already exists") {
                versionsState = .error(msg)
                return
            }
        }

        loadingMessage = "Loading versions..."
        do {
            let result = try await service.listVersions(app: app, account: account)
            applyVersions(result)
            await fetchDisplayNames(service: service)
        } catch {
            versionsState = .error(error.localizedDescription)
            selectedVersionId = nil
        }
    }

    private func applyVersions(_ result: VersionsOutput) {
        let versions = result.versionIds.reversed().map { id in
            AppVersion(id: id, isLatest: id == result.latestVersionId, displayVersion: nil)
        }
        versionsState = .loaded(versions)
        selectedVersionId = result.latestVersionId
    }

    private func fetchDisplayNames(service: AppStoreService) async {
        guard case .loaded(let versions) = versionsState else { return }
        let app = self.app
        let account = self.account

        await withTaskGroup(of: (String, String?).self) { group in
            for version in versions {
                group.addTask {
                    let name = try? await service.fetchVersionDisplayName(
                        app: app, account: account, versionId: version.id
                    )
                    return (version.id, name)
                }
            }

            for await (id, displayVersion) in group {
                guard displayVersion != nil,
                      case .loaded(var current) = self.versionsState,
                      let index = current.firstIndex(where: { $0.id == id }) else { continue }
                current[index].displayVersion = displayVersion
                self.versionsState = .loaded(current)
            }
        }
    }

    var selectedDisplayVersion: String? {
        guard let id = selectedVersionId, case .loaded(let versions) = versionsState else { return nil }
        return versions.first(where: { $0.id == id })?.displayVersion
    }

    func initiateDownload() {
        let savePanel = NSSavePanel()
        savePanel.title = "Save App File"
        savePanel.canCreateDirectories = true

        let downloadType = getDownloadTypeFromSettings()
        let fileExtension = downloadType.rawValue
        let versionLabel = selectedDisplayVersion ?? app.version ?? ""
        let fileName = "\(app.bundleID ?? "")_\(versionLabel).\(fileExtension)"
        savePanel.nameFieldStringValue = fileName

        if let contentType = UTType(filenameExtension: fileExtension) {
            savePanel.allowedContentTypes = [contentType]
        }

        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let settings = try? JSONDecoder().decode(SettingsModel.self, from: data),
           !settings.defaultDownloadPath.isEmpty {
            savePanel.directoryURL = URL(fileURLWithPath: settings.defaultDownloadPath)
        }

        savePanel.begin { [weak self] response in
            if response == .OK, let url = savePanel.url {
                Task { @MainActor in
                    self?.startDownload(at: url)
                }
            }
        }
    }

    private func startDownload(at url: URL) {
        downloadState = .purchasing
        Task {
            do {
                let service = AppStoreService()
                _ = try await service.download(
                    app: app,
                    account: account,
                    outputPath: url.path,
                    externalVersionId: selectedVersionId,
                    progress: { progress, bytesWritten, totalBytes in
                        Task { @MainActor in
                            self.downloadState = .downloading(
                                progress: progress,
                                bytesWritten: bytesWritten,
                                totalBytes: totalBytes
                            )
                        }
                    },
                    modelContext: modelContext
                )
                downloadState = .idle
            } catch {
                if let loginError = error as? LoginError, loginError == .tokenExpired {
                    await loginViewModel?.logout(withMessage: "Session expired. Please login again.")
                } else {
                    errorMessage = error.localizedDescription
                    downloadState = .idle
                }
            }
        }
    }

    var isDownloading: Bool {
        switch downloadState {
        case .idle: return false
        default: return true
        }
    }

    private func getDownloadTypeFromSettings() -> DownloadType {
        if let data = UserDefaults.standard.data(forKey: "UserSettings"),
           let settings = try? JSONDecoder().decode(SettingsModel.self, from: data) {
            return settings.defaultDownloadType
        }
        return .ipa
    }
}
