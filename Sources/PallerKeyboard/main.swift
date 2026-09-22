import AppKit
import CoreGraphics

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let applicationDelegate = AppDelegate()
    application.delegate = applicationDelegate
    application.setActivationPolicy(.accessory)
    application.run()
    _ = applicationDelegate
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keyboardState = KeyboardState()
    private let nativeWallpaperManager = NativeWallpaperManager()
    private var wallpaperController: WallpaperController!
    private var inputMonitor: InputMonitor!
    private var statusItem: NSStatusItem!
    private var amountMenuItem: NSMenuItem!
    private var inputStatusMenuItem: NSMenuItem!
    private var incrementSummaryMenuItem: NSMenuItem!
    private var midnightResetMenuItem: NSMenuItem!
    private var fixedPresetItems: [NSMenuItem] = []
    private var randomRangeMenuItem: NSMenuItem!
    private var nativeWallpaperStatusMenuItem: NSMenuItem!
    private var nativeWallpaperStatus = "系统壁纸：准备设置"

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyNativeWallpaper(showError: false)

        wallpaperController = WallpaperController(state: keyboardState)
        wallpaperController.rebuildWindows()

        inputMonitor = InputMonitor(
            handler: { [weak self] keyCode, isDown, shouldCount in
                self?.keyboardState.setKey(code: keyCode, isDown: isDown, shouldCount: shouldCount)
            },
            mouseHandler: { [weak self] location in
                self?.wallpaperController.handleGlobalMouseDown(at: location)
            }
        )

        configureStatusItem()
        startInputMonitoring(requestPermission: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = Bundle.main.image(forResource: "FishboneTemplate") {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                image.accessibilityDescription = "Mijine 的收银台"
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Mijine 的收银台")
            }
        }
        buildMenu()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        amountMenuItem = NSMenuItem(title: "今日金额：0.00", action: nil, keyEquivalent: "")
        amountMenuItem.isEnabled = false
        menu.addItem(amountMenuItem)

        inputStatusMenuItem = NSMenuItem(title: "输入监听：等待授权", action: nil, keyEquivalent: "")
        inputStatusMenuItem.isEnabled = false
        menu.addItem(inputStatusMenuItem)
        menu.addItem(.separator())

        let incrementItem = NSMenuItem(title: "每次按键增加", action: nil, keyEquivalent: "")
        let incrementMenu = NSMenu()
        incrementSummaryMenuItem = NSMenuItem(title: "当前：固定 0.01", action: nil, keyEquivalent: "")
        incrementSummaryMenuItem.isEnabled = false
        incrementMenu.addItem(incrementSummaryMenuItem)
        incrementMenu.addItem(.separator())

        for cents in [1, 5, 10, 50, 100] {
            let title = String(format: "固定 %.2f", Double(cents) / 100.0)
            let item = NSMenuItem(title: title, action: #selector(selectFixedPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cents
            incrementMenu.addItem(item)
            fixedPresetItems.append(item)
        }

        let customFixed = NSMenuItem(title: "自定义固定金额…", action: #selector(configureFixedIncrement), keyEquivalent: "")
        customFixed.target = self
        incrementMenu.addItem(customFixed)
        incrementMenu.addItem(.separator())

        randomRangeMenuItem = NSMenuItem(title: "随机金额范围…", action: #selector(configureRandomIncrement), keyEquivalent: "")
        randomRangeMenuItem.target = self
        incrementMenu.addItem(randomRangeMenuItem)
        incrementItem.submenu = incrementMenu
        menu.addItem(incrementItem)

        midnightResetMenuItem = NSMenuItem(title: "每天 0 点自动清零", action: #selector(toggleMidnightReset), keyEquivalent: "")
        midnightResetMenuItem.target = self
        menu.addItem(midnightResetMenuItem)

        let clearItem = NSMenuItem(title: "立即清空金额…", action: #selector(clearAmount), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(.separator())
        let notesItem = NSMenuItem(title: "桌面便签", action: nil, keyEquivalent: "")
        let notesMenu = NSMenu()
        for kind in DesktopNoteKind.allCases {
            let item = NSMenuItem(title: kind.menuTitle, action: #selector(toggleDesktopNote(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            notesMenu.addItem(item)
        }
        notesItem.submenu = notesMenu
        menu.addItem(notesItem)
        menu.addItem(withTitle: "重新检查权限并启动", action: #selector(retryInputMonitoring), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "打开“输入监控”设置", action: #selector(openInputSettings), keyEquivalent: "") .target = self
        menu.addItem(withTitle: "刷新桌面窗口", action: #selector(screensChanged), keyEquivalent: "") .target = self
        menu.addItem(withTitle: "重新应用系统壁纸", action: #selector(reapplyNativeWallpaper), keyEquivalent: "") .target = self
        nativeWallpaperStatusMenuItem = NSMenuItem(title: nativeWallpaperStatus, action: nil, keyEquivalent: "")
        nativeWallpaperStatusMenuItem.isEnabled = false
        menu.addItem(nativeWallpaperStatusMenuItem)
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let versionItem = NSMenuItem(title: "Mijine Bar 版本 \(version)（\(build)）", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(withTitle: "退出 Mijine 的收银台", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        updateMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }

    private func updateMenuState() {
        amountMenuItem?.title = "今日金额：\(keyboardState.amountText)"
        inputStatusMenuItem?.title = inputMonitor?.isRunning == true ? "输入监听：已启用" : "输入监听：等待授权"
        incrementSummaryMenuItem?.title = "当前：\(keyboardState.incrementDescription)"
        midnightResetMenuItem?.state = keyboardState.resetsAtMidnight ? .on : .off
        randomRangeMenuItem?.state = keyboardState.incrementMode == .random ? .on : .off
        for item in fixedPresetItems {
            let cents = item.representedObject as? Int
            item.state = keyboardState.incrementMode == .fixed && cents == keyboardState.fixedIncrementCents ? .on : .off
        }
    }

    private func startInputMonitoring(requestPermission: Bool) {
        let started = inputMonitor.start(requestPermission: requestPermission)
        keyboardState.hasInputPermission = started
        updateMenuState()
    }

    @objc private func selectFixedPreset(_ sender: NSMenuItem) {
        guard let cents = sender.representedObject as? Int else { return }
        keyboardState.useFixedIncrement(cents: cents)
        updateMenuState()
    }

    @objc private func configureFixedIncrement() {
        inputMonitor.stop()
        defer { startInputMonitoring(requestPermission: false) }

        let field = NSTextField(string: String(format: "%.2f", Double(keyboardState.fixedIncrementCents) / 100.0))
        field.placeholderString = "例如 0.25"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)

        let alert = NSAlert()
        alert.messageText = "设置固定增加金额"
        alert.informativeText = "每次按键增加多少金额，最低为 0.01。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let cents = parseCents(field.stringValue) else {
            showInvalidAmountAlert()
            return
        }
        keyboardState.useFixedIncrement(cents: cents)
        updateMenuState()
    }

    @objc private func configureRandomIncrement() {
        inputMonitor.stop()
        defer { startInputMonitoring(requestPermission: false) }

        let minimumField = NSTextField(string: String(format: "%.2f", Double(keyboardState.randomMinimumCents) / 100.0))
        let maximumField = NSTextField(string: String(format: "%.2f", Double(keyboardState.randomMaximumCents) / 100.0))
        minimumField.placeholderString = "0.01"
        maximumField.placeholderString = "1.00"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "最小值"), minimumField],
            [NSTextField(labelWithString: "最大值"), maximumField]
        ])
        grid.column(at: 1).width = 180
        grid.rowSpacing = 8

        let alert = NSAlert()
        alert.messageText = "设置随机增加范围"
        alert.informativeText = "每次按键会在 0.01～1.00 之间随机增加，精确到 0.01。"
        alert.accessoryView = grid
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let minimum = parseCents(minimumField.stringValue),
              let maximum = parseCents(maximumField.stringValue),
              minimum <= 100,
              maximum <= 100,
              maximum >= minimum else {
            showInvalidAmountAlert()
            return
        }
        keyboardState.useRandomIncrement(minimumCents: minimum, maximumCents: maximum)
        updateMenuState()
    }

    @objc private func toggleMidnightReset() {
        keyboardState.setResetsAtMidnight(!keyboardState.resetsAtMidnight)
        updateMenuState()
    }

    @objc private func clearAmount() {
        inputMonitor.stop()
        defer { startInputMonitoring(requestPermission: false) }

        let alert = NSAlert()
        alert.messageText = "清空当前金额？"
        alert.informativeText = "收银机金额将立即变为 0.00。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            keyboardState.resetAmount()
            updateMenuState()
        }
    }

    private func parseCents(_ value: String) -> Int? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount.isFinite, amount >= 0.01 else { return nil }
        let cents = (amount * 100).rounded()
        guard cents <= Double(Int.max) else { return nil }
        return Int(cents)
    }

    private func showInvalidAmountAlert() {
        let alert = NSAlert()
        alert.messageText = "金额格式不正确"
        alert.informativeText = "固定金额应不小于 0.01；随机范围必须位于 0.01～1.00，并且最大值不小于最小值。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func retryInputMonitoring() {
        startInputMonitoring(requestPermission: true)
    }

    @objc private func toggleDesktopNote(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let kind = DesktopNoteKind(rawValue: rawValue) else { return }
        wallpaperController.toggleNote(kind)
    }

    @objc private func openInputSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func screensChanged() {
        applyNativeWallpaper(showError: false)
        wallpaperController.rebuildWindows()
    }

    @objc private func reapplyNativeWallpaper() {
        applyNativeWallpaper(showError: true)
    }

    private func applyNativeWallpaper(showError: Bool) {
        switch nativeWallpaperManager.applyToAllScreens() {
        case .success:
            nativeWallpaperStatus = "系统壁纸：已应用"
        case .missingResource:
            nativeWallpaperStatus = "系统壁纸：找不到图片"
            if showError {
                showWallpaperError("App 中缺少 KrustyKrab.jpg 壁纸资源。")
            }
        case .partialFailure(let messages):
            nativeWallpaperStatus = "系统壁纸：部分显示器设置失败"
            if showError {
                showWallpaperError(messages.joined(separator: "\n"))
            }
        }
        nativeWallpaperStatusMenuItem?.title = nativeWallpaperStatus
    }

    private func showWallpaperError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法设置系统壁纸"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
