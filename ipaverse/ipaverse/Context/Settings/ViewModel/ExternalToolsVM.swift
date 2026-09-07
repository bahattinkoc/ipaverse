//
//  ExternalToolsVM.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//

import SwiftUI

@MainActor
final class ExternalToolsVM: ObservableObject {
    @Published private(set) var statuses: [String: ToolStatus] = [:]
    @Published private(set) var busyToolID: String?
    @Published private(set) var lastLogLine: [String: String] = [:]
    @Published var errorMessage: String?
    @Published private(set) var homebrewAvailable = true

    func refreshAll() {
        homebrewAvailable = ExternalToolManager.homebrewPath() != nil
        for tool in ExternalToolManager.catalog {
            statuses[tool.id] = ExternalToolManager.status(for: tool)
        }
    }

    func status(for tool: ExternalTool) -> ToolStatus {
        statuses[tool.id] ?? .unknown
    }

    func install(_ tool: ExternalTool) {
        guard busyToolID == nil else { return }
        busyToolID = tool.id
        statuses[tool.id] = .checking
        Task {
            do {
                try await ExternalToolManager.install(tool) { [weak self] line in
                    Task { @MainActor in self?.lastLogLine[tool.id] = line }
                }
            } catch {
                errorMessage = "Couldn't install \(tool.name): \(error.localizedDescription)"
            }
            statuses[tool.id] = ExternalToolManager.status(for: tool)
            busyToolID = nil
        }
    }

    func uninstall(_ tool: ExternalTool) {
        guard busyToolID == nil else { return }
        busyToolID = tool.id
        statuses[tool.id] = .checking
        Task {
            do {
                try await ExternalToolManager.uninstall(tool) { [weak self] line in
                    Task { @MainActor in self?.lastLogLine[tool.id] = line }
                }
            } catch {
                errorMessage = "Couldn't uninstall \(tool.name): \(error.localizedDescription)"
            }
            statuses[tool.id] = ExternalToolManager.status(for: tool)
            busyToolID = nil
        }
    }
}
