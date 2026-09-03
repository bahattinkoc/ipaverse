//
//  IPAInstallContext.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 3.09.2026.
//

import Foundation

/// Identity for a "Install to Device" sheet — shared between DownloadedView
/// and ResigningWindowView, both of which can trigger a device install.
struct IPAInstallContext: Identifiable {
    let id = UUID()
    let ipaPath: String
    let appName: String
}
