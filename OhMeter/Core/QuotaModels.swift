import Foundation

// MARK: - Language

enum LanguageChoice: String, Codable, Sendable {
    case auto
    case chinese
    case english

    func resolved() -> String {
        switch self {
        case .auto:
            let langs = Locale.preferredLanguages
            if let first = langs.first, first.lowercased().hasPrefix("zh") {
                return "zh"
            }
            return "en"
        case .chinese:
            return "zh"
        case .english:
            return "en"
        }
    }
}

// MARK: - Display Mode

enum DisplayMode: String, Codable, Sendable {
    case fiveHour = "5h"
    case sevenDay = "7d"
}
