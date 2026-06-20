//
//  SettingsView.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 18.08.2025.
//

import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @StateObject private var viewModel = SettingsVM()
    @EnvironmentObject var loginViewModel: LoginVM

    var body: some View {
        TabView {
            accountTab
                .tabItem { Label("Account", systemImage: "person.crop.circle") }

            downloadsTab
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            searchTab
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 440)
    }

    // MARK: - Tabs

    private var accountTab: some View {
        NavigationStack {
            Form {
                profileSection
                accountSection
            }
            .formStyle(.grouped)
        }
    }

    private var downloadsTab: some View {
        Form {
            downloadsSection
        }
        .formStyle(.grouped)
    }

    private var searchTab: some View {
        Form {
            searchSection
        }
        .formStyle(.grouped)
    }

    /// Closes the Settings window (it's a standard window with its own close
    /// button, so we dismiss it via AppKit when an action navigates away).
    private func closeSettingsWindow() {
        NSApp.keyWindow?.close()
    }

    // MARK: - Profile

    private var profileSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Text(initials)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(loginViewModel.currentAccount?.name ?? "—")
                        .font(.headline)
                        .lineLimit(1)

                    Text(loginViewModel.currentAccount?.email ?? "—")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.vertical, 6)

            NavigationLink {
                RegionPickerView()
                    .environmentObject(loginViewModel)
            } label: {
                LabeledContent {
                    HStack(spacing: 4) {
                        if let flag = currentRegion?.flagEmoji {
                            Text(flag)
                        }
                        Text(regionName ?? "Not Set")
                            .foregroundColor(.secondary)
                    }
                } label: {
                    Label("App Store Region", systemImage: "storefront")
                }
            }
        } header: {
            Text("Profile")
        }
    }

    private var initials: String {
        guard let name = loginViewModel.currentAccount?.name, !name.isEmpty else { return "?" }
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    private var currentRegion: StoreFrontCatalog.Region? {
        guard let sf = loginViewModel.currentAccount?.storeFront else { return nil }
        return StoreFrontCatalog.region(for: sf)
    }

    private var regionName: String? { currentRegion?.name }

    // MARK: - Downloads

    private var downloadsSection: some View {
        Section {
            LabeledContent {
                Button {
                    viewModel.selectDownloadPath()
                } label: {
                    HStack(spacing: 4) {
                        Text(saveFolderName)
                            .lineLimit(1)
                            .foregroundColor(viewModel.settings.defaultDownloadPath.isEmpty ? .secondary : .primary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                }
                .buttonStyle(.plain)
            } label: {
                Label("Save Location", systemImage: "folder")
            }

            LabeledContent {
                Picker("", selection: $viewModel.settings.defaultDownloadType) {
                    ForEach(DownloadType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: viewModel.settings.defaultDownloadType) { _, _ in
                    viewModel.saveSettings()
                }
            } label: {
                Label("File Format", systemImage: "doc")
            }
        } header: {
            Text("Downloads")
        }
    }

    private var saveFolderName: String {
        let path = viewModel.settings.defaultDownloadPath
        guard !path.isEmpty else { return "Not Set" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Search

    private var searchSection: some View {
        Section {
            LabeledContent {
                Picker("", selection: $viewModel.settings.searchResultLimit) {
                    ForEach(SearchResultLimit.allCases) { limit in
                        Text(limit.displayName).tag(limit)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: viewModel.settings.searchResultLimit) { _, _ in
                    viewModel.saveSettings()
                }
            } label: {
                Label("Search Results", systemImage: "list.number")
            }

            Toggle(isOn: Binding(
                get: { viewModel.settings.searchHistoryEnabled },
                set: { _ in viewModel.toggleSearchHistory() }
            )) {
                Label("Save Search History", systemImage: "clock")
            }

            if viewModel.settings.searchHistoryEnabled {
                Button(role: .destructive) {
                    viewModel.clearSearchHistory()
                } label: {
                    Label("Clear Search History", systemImage: "trash")
                }
            }
        } header: {
            Text("Search")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            Button {
                Task {
                    closeSettingsWindow()
                    await loginViewModel.logout()
                }
            } label: {
                Label("Add / Switch Account", systemImage: "person.2.circle")
            }

            Button(role: .destructive) {
                Task {
                    closeSettingsWindow()
                    await loginViewModel.signOutCompletely()
                }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            Text("Account")
        }
    }
}

// MARK: - RegionPickerView

struct RegionPickerView: View {
    @EnvironmentObject private var loginViewModel: LoginVM
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var regions: [StoreFrontCatalog.Region] { StoreFrontCatalog.allRegions }

    private var filtered: [StoreFrontCatalog.Region] {
        guard !searchText.isEmpty else { return regions }
        return regions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var currentStoreFrontID: String? {
        guard let sf = loginViewModel.currentAccount?.storeFront else { return nil }
        return sf.components(separatedBy: "-").first ?? sf
    }

    private var defaultRegion: StoreFrontCatalog.Region? {
        guard let code = loginViewModel.originalStoreFrontCode else { return nil }
        return StoreFrontCatalog.region(for: code)
    }

    var body: some View {
        List(filtered) { region in
            Button {
                loginViewModel.changeStoreFront(region.storeFrontID)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text(region.flagEmoji)
                        .font(.system(size: 20))
                        .frame(width: 28)
                    Text(region.name)
                        .foregroundColor(.primary)
                        .font(.body)
                    Spacer()
                    if currentStoreFrontID == region.storeFrontID {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                            .fontWeight(.semibold)
                            .font(.body)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search countries...")
        .navigationTitle("App Store Region")
        .toolbar {
            if loginViewModel.isUsingCustomRegion {
                ToolbarItem(placement: .automatic) {
                    Button {
                        loginViewModel.resetToDefaultStoreFront()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text(defaultRegion.map { "Reset to \($0.name)" } ?? "Reset to Default")
                        }
                    }
                    .help("Restore your account's original App Store region")
                }
            }
        }
    }
}

// MARK: - Storefront Data

fileprivate let appStoreStoreFronts: [String: String] = [
    "143441": "United States",      "143442": "France",             "143443": "Germany",
    "143444": "United Kingdom",     "143445": "Austria",            "143446": "Belgium",
    "143447": "Finland",            "143448": "Greece",             "143449": "Ireland",
    "143450": "Italy",              "143451": "Luxembourg",         "143452": "Netherlands",
    "143453": "Portugal",           "143454": "Spain",              "143455": "Canada",
    "143456": "Sweden",             "143457": "Norway",             "143458": "Denmark",
    "143459": "Switzerland",        "143460": "Australia",          "143461": "New Zealand",
    "143462": "Japan",              "143463": "Hong Kong",          "143464": "Singapore",
    "143465": "China",              "143466": "South Korea",        "143467": "India",
    "143468": "Mexico",             "143469": "Russia",             "143470": "Taiwan",
    "143471": "Vietnam",            "143472": "South Africa",       "143473": "Malaysia",
    "143474": "Philippines",        "143475": "Thailand",           "143476": "Indonesia",
    "143477": "Pakistan",           "143478": "Poland",             "143479": "Saudi Arabia",
    "143480": "Turkey",             "143481": "UAE",                "143482": "Hungary",
    "143483": "Chile",              "143484": "Nepal",              "143485": "Panama",
    "143486": "Sri Lanka",          "143487": "Romania",            "143488": "Maldives",
    "143489": "Czech Republic",     "143490": "Bangladesh",         "143491": "Israel",
    "143492": "Ukraine",            "143493": "Kuwait",             "143494": "Croatia",
    "143495": "Costa Rica",         "143496": "Slovakia",           "143497": "Lebanon",
    "143498": "Qatar",              "143499": "Slovenia",           "143500": "Serbia",
    "143501": "Colombia",           "143502": "Venezuela",          "143503": "Brazil",
    "143504": "Guatemala",          "143505": "Argentina",          "143506": "El Salvador",
    "143507": "Peru",               "143508": "Dominican Republic", "143509": "Ecuador",
    "143510": "Honduras",           "143511": "Jamaica",            "143512": "Nicaragua",
    "143513": "Paraguay",           "143514": "Uruguay",            "143515": "Macau",
    "143516": "Egypt",              "143517": "Kazakhstan",         "143518": "Estonia",
    "143519": "Latvia",             "143520": "Lithuania",          "143521": "Malta",
    "143522": "Liechtenstein",      "143523": "Moldova",            "143524": "Armenia",
    "143525": "Botswana",           "143526": "Bulgaria",           "143527": "Ivory Coast",
    "143528": "Jordan",             "143529": "Kenya",              "143530": "Macedonia",
    "143531": "Madagascar",         "143532": "Mali",               "143533": "Mauritius",
    "143534": "Niger",              "143535": "Senegal",            "143536": "Tunisia",
    "143537": "Uganda",             "143538": "Anguilla",           "143539": "Bahamas",
    "143540": "Antigua & Barbuda",  "143541": "Barbados",           "143542": "Bermuda",
    "143543": "Virgin Islands",     "143544": "Cayman Islands",     "143545": "Dominica",
    "143546": "Grenada",            "143547": "Montserrat",         "143548": "St. Kitts & Nevis",
    "143549": "St. Lucia",          "143550": "St. Vincent & Grenadines",
    "143551": "Trinidad & Tobago",  "143552": "Turks & Caicos Islands",
    "143553": "Guyana",             "143554": "Suriname",           "143555": "Belize",
    "143556": "Bolivia",            "143557": "Cyprus",             "143558": "Iceland",
    "143559": "Bahrain",            "143560": "Brunei",             "143561": "Nigeria",
    "143562": "Oman",               "143563": "Algeria",            "143564": "Angola",
    "143565": "Belarus",            "143566": "Uzbekistan",         "143568": "Azerbaijan",
    "143572": "Tanzania",           "143573": "Ghana",              "143575": "Albania",
    "143592": "Mongolia",           "143615": "Georgia",            "143617": "Iraq"
]
