//
//  StoreFrontCatalog.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 25.05.2025.
//

import Foundation

enum StoreFrontCatalog {

    struct Region: Identifiable {
        let storeFrontID: String
        let countryCode: String

        var id: String { storeFrontID }

        var name: String {
            Locale(identifier: "en_US").localizedString(forRegionCode: countryCode) ?? countryCode
        }

        var flagEmoji: String {
            countryCode.uppercased().unicodeScalars.reduce("") {
                guard let scalar = Unicode.Scalar(127397 + $1.value) else { return $0 }
                return $0 + String(scalar)
            }
        }
    }

    // MARK: - Lookups

    static func region(for storeFront: String) -> Region? {
        let id = storeFront.components(separatedBy: "-").first ?? storeFront
        guard let code = table[id] else { return nil }
        return Region(storeFrontID: id, countryCode: code)
    }

    static func countryCode(for storeFront: String) -> String? {
        region(for: storeFront)?.countryCode
    }

    /// Lowercase country code for App Store search API (falls back to "us")
    static func searchCountryCode(for storeFront: String) -> String {
        countryCode(for: storeFront)?.lowercased() ?? "us"
    }

    static var allRegions: [Region] {
        table
            .map { Region(storeFrontID: $0.key, countryCode: $0.value) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - Table (storeFrontID → ISO 3166-1 alpha-2)

    static let table: [String: String] = [
        "143441": "US", "143442": "FR", "143443": "DE", "143444": "GB", "143445": "AT",
        "143446": "BE", "143447": "FI", "143448": "GR", "143449": "IE", "143450": "IT",
        "143451": "LU", "143452": "NL", "143453": "PT", "143454": "ES", "143455": "CA",
        "143456": "SE", "143457": "NO", "143458": "DK", "143459": "CH", "143460": "AU",
        "143461": "NZ", "143462": "JP", "143463": "HK", "143464": "SG", "143465": "CN",
        "143466": "KR", "143467": "IN", "143468": "MX", "143469": "RU", "143470": "TW",
        "143471": "VN", "143472": "ZA", "143473": "MY", "143474": "PH", "143475": "TH",
        "143476": "ID", "143477": "PK", "143478": "PL", "143479": "SA", "143480": "TR",
        "143481": "AE", "143482": "HU", "143483": "CL", "143484": "NP", "143485": "PA",
        "143486": "LK", "143487": "RO", "143488": "MV", "143489": "CZ", "143490": "BD",
        "143491": "IL", "143492": "UA", "143493": "KW", "143494": "HR", "143495": "CR",
        "143496": "SK", "143497": "LB", "143498": "QA", "143499": "SI", "143500": "RS",
        "143501": "CO", "143502": "VE", "143503": "BR", "143504": "GT", "143505": "AR",
        "143506": "SV", "143507": "PE", "143508": "DO", "143509": "EC", "143510": "HN",
        "143511": "JM", "143512": "NI", "143513": "PY", "143514": "UY", "143515": "MO",
        "143516": "EG", "143517": "KZ", "143518": "EE", "143519": "LV", "143520": "LT",
        "143521": "MT", "143522": "LI", "143523": "MD", "143524": "AM", "143525": "BW",
        "143526": "BG", "143527": "CI", "143528": "JO", "143529": "KE", "143530": "MK",
        "143531": "MG", "143532": "ML", "143533": "MU", "143534": "NE", "143535": "SN",
        "143536": "TN", "143537": "UG", "143538": "AI", "143539": "BS", "143540": "AG",
        "143541": "BB", "143542": "BM", "143543": "VG", "143544": "KY", "143545": "DM",
        "143546": "GD", "143547": "MS", "143548": "KN", "143549": "LC", "143550": "VC",
        "143551": "TT", "143552": "TC", "143553": "GY", "143554": "SR", "143555": "BZ",
        "143556": "BO", "143557": "CY", "143558": "IS", "143559": "BH", "143560": "BN",
        "143561": "NG", "143562": "OM", "143563": "DZ", "143564": "AO", "143565": "BY",
        "143566": "UZ", "143568": "AZ", "143572": "TZ", "143573": "GH", "143575": "AL",
        "143592": "MN", "143615": "GE", "143617": "IQ"
    ]
}
