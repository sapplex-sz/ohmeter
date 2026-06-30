import Foundation

/// Bilingual string helper — returns Chinese or English based on language code.
struct L {
    static func tr(_ lang: String, zh: String, en: String) -> String {
        lang == "zh" ? zh : en
    }

    // MARK: - Menu Labels

    static func menuBarDisplay(_ lang: String) -> String { tr(lang, zh: "菜单栏显示", en: "Menu bar display") }
    static func fiveHours(_ lang: String) -> String { tr(lang, zh: "5 小时", en: "5 hours") }
    static func sevenDays(_ lang: String) -> String { tr(lang, zh: "7 天", en: "7 days") }

    static func language(_ lang: String) -> String { tr(lang, zh: "语言", en: "Language") }
    static func followSystem(_ lang: String) -> String { tr(lang, zh: "跟随系统", en: "Follow System") }

    static func launchAtLogin(_ lang: String) -> String { tr(lang, zh: "开机自启", en: "Launch at Login") }
    static func refreshNow(_ lang: String) -> String { tr(lang, zh: "立即刷新", en: "Refresh now") }
    static func openCodexAnalytics(_ lang: String) -> String { tr(lang, zh: "打开 Codex 分析页", en: "Open Codex analytics") }
    static func about(_ lang: String, version: String) -> String {
        tr(lang, zh: "关于（OhMeter \(version)）", en: "About (OhMeter \(version))")
    }
    static func quit(_ lang: String) -> String { tr(lang, zh: "退出", en: "Quit") }
    static func lastRefresh(_ lang: String, time: String) -> String {
        tr(lang, zh: "上次刷新: \(time)", en: "Last refresh: \(time)")
    }

    // MARK: - Reset Time Formatting

    static func formatResetDate(_ date: Date, lang: String) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0

        let timeStr = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))

        let zhWeekdays = "一二三四五六日"
        let enWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let weekday = calendar.component(.weekday, from: date) - 1
        let idx = (weekday + 6) % 7

        let currentWeek = calendar.component(.weekOfYear, from: Date())
        let targetWeek = calendar.component(.weekOfYear, from: date)

        if lang == "zh" {
            if days == 0 { return "今天 \(timeStr)" }
            if days == 1 { return "明天 \(timeStr)" }
            if days == 2 { return "后天 \(timeStr)" }
            let prefix = targetWeek > currentWeek ? "下周" : "周"
            return "\(prefix)\(zhWeekdays[zhWeekdays.index(zhWeekdays.startIndex, offsetBy: idx)]) \(timeStr)"
        } else {
            if days == 0 { return "today \(timeStr)" }
            if days == 1 { return "tomorrow \(timeStr)" }
            if days == 2 { return "in 2 days \(timeStr)" }
            let prefix = targetWeek > currentWeek ? "next " : ""
            return "\(prefix)\(enWeekdays[idx]) \(timeStr)"
        }
    }
}
