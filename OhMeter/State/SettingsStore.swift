import Foundation
import Darwin

/// Persists user settings and cached Codex quota data using UserDefaults.
final class SettingsStore {

    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Key {
        static let displayMode = "ohmeter.displayMode"
        static let language = "ohmeter.language"
        static let cacheData = "ohmeter.codexCache"
        static let cacheTimestamp = "ohmeter.cacheTimestamp"
        static let codexHomeBookmark = "ohmeter.codexHomeBookmark"
        static let codexHomeRelativePath = "ohmeter.codexHomeRelativePath"
    }

    // MARK: - Display Mode

    var displayMode: DisplayMode {
        get {
            guard let raw = defaults.string(forKey: Key.displayMode),
                  let mode = DisplayMode(rawValue: raw) else {
                return .fiveHour
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Key.displayMode) }
    }

    // MARK: - Language

    var languageChoice: LanguageChoice {
        get {
            guard let raw = defaults.string(forKey: Key.language),
                  let choice = LanguageChoice(rawValue: raw) else {
                return .auto
            }
            return choice
        }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }

    var currentLang: String {
        languageChoice.resolved()
    }

    // MARK: - Codex Home Access

    struct ScopedCodexHomeAccess {
        let url: URL
        fileprivate let scopedURL: URL
        fileprivate let didStartAccessing: Bool

        func stopAccessing() {
            if didStartAccessing {
                scopedURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    var hasCodexHomeAccess: Bool {
        defaults.data(forKey: Key.codexHomeBookmark) != nil
    }

    func saveCodexHomeAccess(url: URL, relativePath: String? = nil) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Key.codexHomeBookmark)
        if let relativePath, !relativePath.isEmpty {
            defaults.set(relativePath, forKey: Key.codexHomeRelativePath)
        } else {
            defaults.removeObject(forKey: Key.codexHomeRelativePath)
        }
    }

    func clearCodexHomeAccess() {
        defaults.removeObject(forKey: Key.codexHomeBookmark)
        defaults.removeObject(forKey: Key.codexHomeRelativePath)
    }

    func startCodexHomeAccess() throws -> ScopedCodexHomeAccess? {
        guard let bookmark = defaults.data(forKey: Key.codexHomeBookmark) else {
            return nil
        }

        var isStale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            try saveCodexHomeAccess(url: scopedURL, relativePath: defaults.string(forKey: Key.codexHomeRelativePath))
        }

        let didStart = scopedURL.startAccessingSecurityScopedResource()
        let effectiveURL: URL
        if let relativePath = defaults.string(forKey: Key.codexHomeRelativePath), !relativePath.isEmpty {
            effectiveURL = scopedURL.appendingPathComponent(relativePath, isDirectory: true)
        } else {
            effectiveURL = scopedURL
        }
        return ScopedCodexHomeAccess(url: effectiveURL, scopedURL: scopedURL, didStartAccessing: didStart)
    }

    static func defaultCodexHomeURL() -> URL {
        if let passwd = getpwuid(getuid()), let home = passwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home)).appendingPathComponent(".codex", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    // MARK: - Codex Quota Cache

    struct CodexCache {
        var fiveHourUsed: Int?
        var sevenDayUsed: Int?
        var fiveHourReset: Date?
        var sevenDayReset: Date?
        var planType: String?
    }

    func saveCodexCache(fiveHourUsed: Int?, sevenDayUsed: Int?,
                        fiveHourReset: Date?, sevenDayReset: Date?,
                        planType: String?) {
        var dict: [String: Any] = [:]
        if let fiveHourUsed {
            dict["fiveHourUsed"] = fiveHourUsed
        }
        if let sevenDayUsed {
            dict["sevenDayUsed"] = sevenDayUsed
        }
        if let fiveHourReset {
            dict["fiveHourReset"] = fiveHourReset.timeIntervalSince1970
        }
        if let sevenDayReset {
            dict["sevenDayReset"] = sevenDayReset.timeIntervalSince1970
        }
        if let planType {
            dict["planType"] = planType
        }
        defaults.set(dict, forKey: Key.cacheData)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.cacheTimestamp)
    }

    func loadCodexCache() -> CodexCache {
        guard let dict = defaults.dictionary(forKey: Key.cacheData) else {
            return CodexCache()
        }
        let legacyFiveHourLeft = dict["fiveHourLeft"] as? Int
        let legacySevenDayLeft = dict["sevenDayLeft"] as? Int
        return CodexCache(
            fiveHourUsed: dict["fiveHourUsed"] as? Int ?? legacyFiveHourLeft.map { Self.clampPercent(100 - $0) },
            sevenDayUsed: dict["sevenDayUsed"] as? Int ?? legacySevenDayLeft.map { Self.clampPercent(100 - $0) },
            fiveHourReset: (dict["fiveHourReset"] as? Double).flatMap { Date(timeIntervalSince1970: $0) },
            sevenDayReset: (dict["sevenDayReset"] as? Double).flatMap { Date(timeIntervalSince1970: $0) },
            planType: dict["planType"] as? String
        )
    }

    private static func clampPercent(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}
