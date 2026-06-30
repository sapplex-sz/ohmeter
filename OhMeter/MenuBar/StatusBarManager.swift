import AppKit
import ServiceManagement

/// Central manager for the OhMeter menu bar app.
/// Displays Codex quota usage for the 5h and 7d windows.
final class StatusBarManager: NSObject, NSMenuDelegate {

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = SettingsStore.shared
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    /// The Codex app-server process manager.
    let server: CodexAppServer

    // Quota data (nil = not yet fetched). Values are used percentages.
    private var fiveHourUsed: Int?
    private var sevenDayUsed: Int?
    private var fiveHourReset: Date?
    private var sevenDayReset: Date?
    private var planType: String?
    private var errorMessage: String?
    private var lastRefresh: Date?
    private var isRefreshing = false

    // Dynamic menu items
    private var dashboardItem: NSMenuItem!
    private var dashboardView: UsageDashboardView!
    private var codexAccessItem: NSMenuItem!
    private var mode5hItem: NSMenuItem!
    private var mode7dItem: NSMenuItem!
    private var langAutoItem: NSMenuItem!
    private var langZhItem: NSMenuItem!
    private var langEnItem: NSMenuItem!
    private var modeMenuItem: NSMenuItem!
    private var langMenuItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private let menuMinWidth: CGFloat = 360

    // MARK: - Init

    init(server: CodexAppServer) {
        self.server = server
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem.button?.title = "OhMeter ..."
        let menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = menuMinWidth
        statusItem.menu = menu
        rebuildMenu()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuContent()
    }

    // MARK: - Language Helper

    private var lang: String { settings.currentLang }

    // MARK: - Refresh

    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        updateStatusBarTitle()
        updateMenuContent()

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            do {
                let quota = try await self.server.fetchQuota()
                await MainActor.run {
                    // New data replaces old data atomically.
                    self.fiveHourUsed = Self.clampPercent(Int(round(quota.primaryUsedPercent)))
                    self.sevenDayUsed = Self.clampPercent(Int(round(quota.secondaryUsedPercent)))
                    self.fiveHourReset = quota.primaryResetsAt
                    self.sevenDayReset = quota.secondaryResetsAt
                    self.planType = quota.planType
                    self.errorMessage = nil
                    self.lastRefresh = Date()
                    self.isRefreshing = false
                    self.updateStatusBarTitle()
                    self.updateMenuContent()
                    self.saveToCache()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isRefreshing = false
                    self.lastRefresh = Date()
                    self.updateStatusBarTitle()
                    self.updateMenuContent()
                }
            }
        }
    }

    func forceRefresh() {
        // Terminate existing process to get fresh data.
        server.terminate()
        isRefreshing = false
        refreshNow()
    }

    // MARK: - Status Bar Title

    private func updateStatusBarTitle() {
        let mode = settings.displayMode

        if errorMessage != nil {
            statusItem.button?.attributedTitle = BatteryIconRenderer.buildAttributedTitle(
                items: [("Codex", 0, true)]
            )
            return
        }

        guard let usedPercent = (mode == .fiveHour ? fiveHourUsed : sevenDayUsed) else {
            statusItem.button?.title = "OhMeter ..."
            return
        }

        let windowLabel = mode == .fiveHour ? "5h" : "7d"
        let label = lang == "zh" ? "\(windowLabel) 剩余" : "\(windowLabel) left"
        let remainingPercent = Self.clampPercent(100 - usedPercent)
        statusItem.button?.attributedTitle = BatteryIconRenderer.buildAttributedTitle(
            items: [(label, remainingPercent, false)]
        )
    }

    // MARK: - Menu Building

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let l = lang

        dashboardView = UsageDashboardView(frame: NSRect(x: 0, y: 0, width: menuMinWidth, height: 164))
        dashboardItem = NSMenuItem()
        dashboardItem.view = dashboardView
        menu.addItem(dashboardItem)
        menu.addItem(.separator())

        codexAccessItem = NSMenuItem(title: "", action: #selector(authorizeCodexAccess), keyEquivalent: "")
        codexAccessItem.target = self
        menu.addItem(codexAccessItem)

        menu.addItem(.separator())

        // Display mode submenu
        mode5hItem = NSMenuItem(title: L.fiveHours(l), action: #selector(setMode5h), keyEquivalent: "")
        mode5hItem.target = self
        mode7dItem = NSMenuItem(title: L.sevenDays(l), action: #selector(setMode7d), keyEquivalent: "")
        mode7dItem.target = self
        modeMenuItem = NSMenuItem(title: L.menuBarDisplay(l), action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        modeMenu.addItem(mode5hItem)
        modeMenu.addItem(mode7dItem)
        modeMenuItem.submenu = modeMenu
        menu.addItem(modeMenuItem)

        // Language submenu
        langAutoItem = NSMenuItem(title: L.followSystem(l), action: #selector(setLangAuto), keyEquivalent: "")
        langAutoItem.target = self
        langZhItem = NSMenuItem(title: "中文", action: #selector(setLangZh), keyEquivalent: "")
        langZhItem.target = self
        langEnItem = NSMenuItem(title: "English", action: #selector(setLangEn), keyEquivalent: "")
        langEnItem.target = self
        langMenuItem = NSMenuItem(title: L.language(l), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        langMenu.addItem(langAutoItem)
        langMenu.addItem(langZhItem)
        langMenu.addItem(langEnItem)
        langMenuItem.submenu = langMenu
        menu.addItem(langMenuItem)

        // Launch at login
        loginItem = NSMenuItem(title: L.launchAtLogin(l), action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        // Actions
        let refreshItem = NSMenuItem(title: L.refreshNow(l), action: #selector(forceRefreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let codexDashItem = NSMenuItem(title: L.openCodexAnalytics(l), action: #selector(openCodexPage), keyEquivalent: "")
        codexDashItem.target = self
        menu.addItem(codexDashItem)

        menu.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(title: L.about(l, version: appVersion), action: nil, keyEquivalent: "")
        let aboutMenu = NSMenu()
        aboutMenu.addItem(makeInertItem("OhMeter \(appVersion)"))
        let descItem = NSMenuItem(title: L.tr(l, zh: "Codex 用量监控（本地 app-server）", en: "Codex usage monitor (local app-server)"), action: nil, keyEquivalent: "")
        descItem.isEnabled = false
        aboutMenu.addItem(descItem)
        aboutItem.submenu = aboutMenu
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: L.quit(l), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        updateMenuContent()
    }

    // MARK: - Menu Content Update

    private func updateMenuContent() {
        dashboardView?.update(snapshot: makeDashboardSnapshot())
        updateMenuChecks()
    }

    private func updateMenuChecks() {
        let l = lang
        let mode = settings.displayMode
        let langChoice = settings.languageChoice

        // Mode
        mode5hItem.title = (mode == .fiveHour ? "✓ " : "  ") + L.fiveHours(l)
        mode7dItem.title = (mode == .sevenDay ? "✓ " : "  ") + L.sevenDays(l)
        let modeLabel = mode == .fiveHour ? L.fiveHours(l) : L.sevenDays(l)
        modeMenuItem.title = L.tr(l,
            zh: "菜单栏显示（\(modeLabel)）",
            en: "Menu bar display (\(modeLabel))")

        // Language
        langAutoItem.title = (langChoice == .auto ? "✓ " : "  ") + L.followSystem(l)
        langZhItem.title = (langChoice == .chinese ? "✓ " : "  ") + "中文"
        langEnItem.title = (langChoice == .english ? "✓ " : "  ") + "English"
        let selLabel: String
        switch langChoice {
        case .auto: selLabel = L.followSystem(l)
        case .chinese: selLabel = "中文"
        case .english: selLabel = "English"
        }
        langMenuItem.title = L.tr(l, zh: "语言（\(selLabel)）", en: "Language (\(selLabel))")

        // Codex data access
        let accessStatus: String
        if settings.hasCodexHomeAccess {
            accessStatus = L.tr(l, zh: "已授权", en: "authorized")
        } else if errorMessage?.localizedCaseInsensitiveContains("authentication required") == true {
            accessStatus = L.tr(l, zh: "需要授权", en: "needs access")
        } else {
            accessStatus = L.tr(l, zh: "未授权", en: "not authorized")
        }
        codexAccessItem.title = L.tr(l, zh: "Codex 数据访问", en: "Codex data access") + "（\(accessStatus)）"

        // Login item
        let loginStatus = SMAppService.mainApp.status
        loginItem.title = L.launchAtLogin(l) + "（\(loginStatusText(loginStatus, lang: l))）"
    }

    // MARK: - Dashboard

    private func makeDashboardSnapshot() -> UsageDashboardSnapshot {
        let l = lang
        let lastRefreshText: String
        if isRefreshing {
            lastRefreshText = L.tr(l, zh: "刷新中...", en: "Refreshing...")
        } else if let lastRefresh {
            let time = lastRefresh.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            lastRefreshText = L.lastRefresh(l, time: time)
        } else {
            lastRefreshText = L.tr(l, zh: "等待首次刷新", en: "Waiting for first refresh")
        }

        return UsageDashboardSnapshot(
            lang: l,
            planTitle: formattedPlanTitle(),
            lastRefreshText: lastRefreshText,
            isRefreshing: isRefreshing,
            errorMessage: friendlyErrorMessage(),
            rows: [
                UsageRowSnapshot(
                    title: L.fiveHours(l),
                    shortTitle: "5h",
                    usedPercent: fiveHourUsed,
                    resetText: fiveHourReset.map { L.formatResetDate($0, lang: l) }
                ),
                UsageRowSnapshot(
                    title: L.sevenDays(l),
                    shortTitle: "7d",
                    usedPercent: sevenDayUsed,
                    resetText: sevenDayReset.map { L.formatResetDate($0, lang: l) }
                ),
            ]
        )
    }

    private func formattedPlanTitle() -> String? {
        guard let planType, !planType.isEmpty else { return nil }
        if planType.lowercased() == "prolite" {
            return "Pro Lite"
        }

        return planType
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + String(word.dropFirst()).lowercased()
            }
            .joined(separator: " ")
    }

    private func friendlyErrorMessage() -> String? {
        guard let errorMessage else { return nil }

        if errorMessage.localizedCaseInsensitiveContains("authentication required") {
            if settings.hasCodexHomeAccess {
                return L.tr(
                    lang,
                    zh: "Codex 登录态不可用。请确认 Codex 已登录，然后立即刷新。",
                    en: "Codex auth is unavailable. Make sure Codex is signed in, then refresh."
                )
            }

            return L.tr(
                lang,
                zh: "需要授权 Codex 数据目录。点击“Codex 数据访问”，选择用户主目录或 ~/.codex。",
                en: "Codex data access is required. Click Codex data access and choose your home folder or ~/.codex."
            )
        }

        if errorMessage.localizedCaseInsensitiveContains("data access required") {
            return L.tr(
                lang,
                zh: "需要授权 Codex 数据目录。点击“Codex 数据访问”，选择用户主目录或 ~/.codex。",
                en: "Codex data access is required. Click Codex data access and choose your home folder or ~/.codex."
            )
        }

        if errorMessage.localizedCaseInsensitiveContains("No local Codex rate limit cache found") {
            return L.tr(
                lang,
                zh: "还没有找到本地额度记录。请先打开 Codex 使用一次，然后回到 OhMeter 立即刷新。",
                en: "No local usage record was found yet. Open Codex once, then refresh OhMeter."
            )
        }

        return errorMessage
    }

    // MARK: - Helpers

    private func makeInertItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(noop), keyEquivalent: "")
        item.target = self
        return item
    }

    private static func clampPercent(_ value: Int) -> Int {
        max(0, min(100, value))
    }

    // MARK: - Cache

    private func saveToCache() {
        settings.saveCodexCache(
            fiveHourUsed: fiveHourUsed,
            sevenDayUsed: sevenDayUsed,
            fiveHourReset: fiveHourReset,
            sevenDayReset: sevenDayReset,
            planType: planType
        )
    }

    func loadFromCache() {
        let cached = settings.loadCodexCache()
        fiveHourUsed = cached.fiveHourUsed
        sevenDayUsed = cached.sevenDayUsed
        fiveHourReset = cached.fiveHourReset
        sevenDayReset = cached.sevenDayReset
        planType = cached.planType
        updateStatusBarTitle()
        updateMenuContent()
    }

    // MARK: - Actions

    @objc private func noop() {}

    @objc private func setMode5h() {
        settings.displayMode = .fiveHour
        updateStatusBarTitle()
        updateMenuChecks()
    }

    @objc private func setMode7d() {
        settings.displayMode = .sevenDay
        updateStatusBarTitle()
        updateMenuChecks()
    }

    @objc private func setLangAuto() {
        settings.languageChoice = .auto
        rebuildMenu()
        updateStatusBarTitle()
    }

    @objc private func setLangZh() {
        settings.languageChoice = .chinese
        rebuildMenu()
        updateStatusBarTitle()
    }

    @objc private func setLangEn() {
        settings.languageChoice = .english
        rebuildMenu()
        updateStatusBarTitle()
    }

    @objc private func authorizeCodexAccess() {
        let l = lang
        let panel = NSOpenPanel()
        panel.title = L.tr(l, zh: "授权 Codex 数据目录", en: "Authorize Codex Data Folder")
        panel.message = L.tr(
            l,
            zh: "请选择你的 .codex 文件夹，或直接选择用户主目录，OhMeter 会使用其中的 .codex。此权限只用于读取本机 Codex 登录态和用量信息。",
            en: "Choose your .codex folder, or select your home folder and OhMeter will use the .codex folder inside it. This access is only used to read local Codex auth and usage data."
        )
        panel.prompt = L.tr(l, zh: "授权", en: "Authorize")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true

        let defaultCodexHome = SettingsStore.defaultCodexHomeURL()
        panel.directoryURL = defaultCodexHome.deletingLastPathComponent()

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        let codexHomeURL = normalizedCodexHomeURL(from: selectedURL)
        guard confirmCodexHomeIfNeeded(codexHomeURL) else {
            return
        }

        do {
            try settings.saveCodexHomeAccess(url: codexHomeURL)
            server.terminate()
            isRefreshing = false
            errorMessage = nil
            updateMenuContent()
            refreshNow()
        } catch {
            showCodexAccessError(error)
        }
    }

    @objc private func toggleLoginItem() {
        let status = SMAppService.mainApp.status
        if status == .requiresApproval {
            openLoginItemsSettings()
            return
        }

        setLoginItem(status != .enabled)
        updateMenuChecks()
    }

    @objc private func forceRefreshAction() {
        forceRefresh()
    }

    @objc private func openCodexPage() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!)
    }

    @objc private func quitApp() {
        server.terminate()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Login Item

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("OhMeter: Failed to \(enabled ? "enable" : "disable") login item: \(error)")
            showLoginItemError(error)
        }
    }

    private func loginStatusText(_ status: SMAppService.Status, lang: String) -> String {
        switch status {
        case .enabled:
            return L.tr(lang, zh: "已开启", en: "enabled")
        case .notRegistered:
            return L.tr(lang, zh: "未开启", en: "off")
        case .requiresApproval:
            return L.tr(lang, zh: "需要允许", en: "needs approval")
        case .notFound:
            return L.tr(lang, zh: "找不到应用", en: "app not found")
        @unknown default:
            return L.tr(lang, zh: "未知", en: "unknown")
        }
    }

    private func showLoginItemError(_ error: Error) {
        let l = lang
        let alert = NSAlert()
        alert.messageText = L.tr(l, zh: "无法开启开机自启", en: "Unable to enable launch at login")
        alert.informativeText = L.tr(
            l,
            zh: "macOS 没有接受当前这个调试版 OhMeter。请把正式构建的 OhMeter 放到“应用程序”文件夹，或到“系统设置 > 通用 > 登录项与后台项目”里允许它。\n\n错误：\(error.localizedDescription)",
            en: "macOS did not accept this debug build of OhMeter. Put a release build in Applications, or allow it in System Settings > General > Login Items & Background Items.\n\nError: \(error.localizedDescription)"
        )
        alert.addButton(withTitle: L.tr(l, zh: "打开系统设置", en: "Open Settings"))
        alert.addButton(withTitle: L.tr(l, zh: "好", en: "OK"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openLoginItemsSettings()
        }
    }

    private func openLoginItemsSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.SystemSettings.GeneralSettings?LoginItems",
        ]

        for rawURL in urls {
            guard let url = URL(string: rawURL) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func normalizedCodexHomeURL(from selectedURL: URL) -> URL {
        if selectedURL.lastPathComponent == ".codex" {
            return selectedURL
        }

        let nestedCodexHome = selectedURL.appendingPathComponent(".codex", isDirectory: true)
        if FileManager.default.fileExists(atPath: nestedCodexHome.path) {
            return nestedCodexHome
        }

        return selectedURL
    }

    private func confirmCodexHomeIfNeeded(_ url: URL) -> Bool {
        let authFile = url.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: authFile.path) {
            return true
        }

        let l = lang
        let alert = NSAlert()
        alert.messageText = L.tr(l, zh: "没有找到 Codex 登录文件", en: "Codex Login File Not Found")
        alert.informativeText = L.tr(
            l,
            zh: "所选目录里没有 auth.json。通常需要选择 ~/.codex，或选择用户主目录让 OhMeter 自动使用 ~/.codex。\n\n当前目录：\(url.path)",
            en: "The selected folder does not contain auth.json. Usually you should choose ~/.codex, or choose your home folder so OhMeter can use ~/.codex automatically.\n\nCurrent folder: \(url.path)"
        )
        alert.addButton(withTitle: L.tr(l, zh: "继续授权", en: "Continue"))
        alert.addButton(withTitle: L.tr(l, zh: "取消", en: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showCodexAccessError(_ error: Error) {
        let l = lang
        let alert = NSAlert()
        alert.messageText = L.tr(l, zh: "无法保存 Codex 数据目录授权", en: "Unable to Save Codex Access")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L.tr(l, zh: "好", en: "OK"))
        alert.runModal()
    }
}

private struct UsageDashboardSnapshot {
    let lang: String
    let planTitle: String?
    let lastRefreshText: String
    let isRefreshing: Bool
    let errorMessage: String?
    let rows: [UsageRowSnapshot]
}

private struct UsageRowSnapshot {
    let title: String
    let shortTitle: String
    let usedPercent: Int?
    let resetText: String?
}

private final class UsageDashboardView: NSView {
    private var snapshot = UsageDashboardSnapshot(
        lang: "en",
        planTitle: nil,
        lastRefreshText: "Waiting for first refresh",
        isRefreshing: false,
        errorMessage: nil,
        rows: []
    )

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 164) }

    func update(snapshot: UsageDashboardSnapshot) {
        self.snapshot = snapshot
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawHeader()

        if let error = snapshot.errorMessage {
            drawError(error)
            return
        }

        let rowTop: CGFloat = 62
        for (index, row) in snapshot.rows.prefix(2).enumerated() {
            drawRow(row, y: rowTop + CGFloat(index) * 49)
        }
    }

    private func drawHeader() {
        let title = "OhMeter"
        drawText(
            title,
            in: NSRect(x: 16, y: 12, width: 112, height: 18),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )

        let plan = snapshot.planTitle.map { "Codex \($0)" } ?? "Codex"
        drawText(
            plan,
            in: NSRect(x: 16, y: 32, width: 150, height: 16),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .secondaryLabelColor
        )

        drawText(
            snapshot.lastRefreshText,
            in: NSRect(x: 160, y: 17, width: bounds.width - 176, height: 28),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: snapshot.isRefreshing ? .systemBlue : .tertiaryLabelColor,
            alignment: .right
        )

        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: NSRect(x: 16, y: 53, width: bounds.width - 32, height: 1)).fill()
    }

    private func drawError(_ error: String) {
        let rect = NSRect(x: 16, y: 72, width: bounds.width - 32, height: 58)
        NSColor.systemRed.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()

        let title = L.tr(snapshot.lang, zh: "读取失败", en: "Unable to read usage")
        drawText(
            title,
            in: NSRect(x: rect.minX + 12, y: rect.minY + 10, width: rect.width - 24, height: 16),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .systemRed
        )

        drawText(
            String(error.prefix(96)),
            in: NSRect(x: rect.minX + 12, y: rect.minY + 29, width: rect.width - 24, height: 18),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .secondaryLabelColor
        )
    }

    private func drawRow(_ row: UsageRowSnapshot, y: CGFloat) {
        let leftX: CGFloat = 16
        let rightX: CGFloat = bounds.width - 16
        let percentWidth: CGFloat = 86
        let percentRect = NSRect(x: rightX - percentWidth, y: y + 1, width: percentWidth, height: 24)
        let titleRect = NSRect(x: leftX, y: y, width: 165, height: 17)
        let metaRect = NSRect(x: leftX, y: y + 18, width: rightX - leftX - percentWidth - 12, height: 15)
        let barRect = NSRect(x: leftX, y: y + 36, width: rightX - leftX, height: 7)

        drawText(
            row.title,
            in: titleRect,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )

        guard let used = row.usedPercent else {
            drawText(
                row.shortTitle + " ...",
                in: percentRect,
                font: .monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
                color: .secondaryLabelColor,
                alignment: .right
            )
            drawText(
                L.tr(snapshot.lang, zh: "等待数据", en: "Waiting for data"),
                in: metaRect,
                font: .systemFont(ofSize: 11, weight: .regular),
                color: .tertiaryLabelColor
            )
            drawProgressBar(in: barRect, usedPercent: nil)
            return
        }

        let remaining = max(0, 100 - used)
        let reset = row.resetText ?? L.tr(snapshot.lang, zh: "未知", en: "unknown")
        let meta = L.tr(
            snapshot.lang,
            zh: "已用 \(used)% · 重置 \(reset)",
            en: "\(used)% used · resets \(reset)"
        )

        drawText(
            meta,
            in: metaRect,
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .secondaryLabelColor
        )

        drawText(
            "\(remaining)%",
            in: percentRect,
            font: .monospacedDigitSystemFont(ofSize: 20, weight: .semibold),
            color: Self.codexPurple,
            alignment: .right
        )

        let remainingLabel = L.tr(snapshot.lang, zh: "剩余", en: "left")
        drawText(
            remainingLabel,
            in: NSRect(x: percentRect.minX, y: y + 25, width: percentWidth, height: 13),
            font: .systemFont(ofSize: 10, weight: .medium),
            color: .tertiaryLabelColor,
            alignment: .right
        )

        drawProgressBar(in: barRect, usedPercent: used)
    }

    private func drawProgressBar(in rect: NSRect, usedPercent: Int?) {
        Self.usedGray.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        guard let usedPercent else { return }
        let clamped = max(0, min(100, usedPercent))
        let remainingPercent = 100 - clamped
        guard remainingPercent > 0 else { return }

        let fillWidth = max(rect.height, rect.width * CGFloat(remainingPercent) / 100)
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: min(fillWidth, rect.width), height: rect.height)
        Self.codexPurple.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private static let codexPurple = NSColor(calibratedRed: 0.43, green: 0.28, blue: 1.0, alpha: 1.0)
    private static let usedGray = NSColor.labelColor.withAlphaComponent(0.14)

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
}
