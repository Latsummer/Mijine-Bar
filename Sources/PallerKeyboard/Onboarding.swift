import AppKit
import CoreGraphics

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let currentVersion = 1

    private enum Step: Int {
        case welcome
        case permission
        case wallpaper
    }

    private let window: NSWindow
    private let contentView = NSView()
    private let stepLabel = NSTextField(labelWithString: "")
    private let bodyContainer = NSView()
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private let permissionStatusLabel = NSTextField(wrappingLabelWithString: "")

    private let requestPermission: () -> Bool
    private let permissionGranted: () -> Void
    private let openInputSettings: () -> Void
    private let finish: (_ applyWallpaper: Bool) -> Void

    private var step: Step = .welcome
    private var permissionTimer: Timer?
    private var reportedPermissionGranted = false
    private var permissionRequestAttempted = false

    init(
        requestPermission: @escaping () -> Bool,
        permissionGranted: @escaping () -> Void,
        openInputSettings: @escaping () -> Void,
        finish: @escaping (_ applyWallpaper: Bool) -> Void
    ) {
        self.requestPermission = requestPermission
        self.permissionGranted = permissionGranted
        self.openInputSettings = openInputSettings
        self.finish = finish
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureWindow()
        configureLayout()
        show(step: .welcome)
    }

    deinit {
        permissionTimer?.invalidate()
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stopPermissionTimer()
    }

    private func configureWindow() {
        window.title = "欢迎使用 Mijine Bar"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.animationBehavior = .documentWindow
        window.contentView = contentView
    }

    private func configureLayout() {
        [stepLabel, bodyContainer, primaryButton, secondaryButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        stepLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.alignment = .center

        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(performPrimaryAction)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.target = self
        secondaryButton.action = #selector(performSecondaryAction)

        NSLayoutConstraint.activate([
            stepLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stepLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            bodyContainer.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 14),
            bodyContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 48),
            bodyContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -48),
            bodyContainer.bottomAnchor.constraint(equalTo: primaryButton.topAnchor, constant: -28),

            primaryButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            primaryButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 116),

            secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -10),
            secondaryButton.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),
            secondaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])
    }

    private func show(step: Step) {
        self.step = step
        stopPermissionTimer()
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }
        stepLabel.stringValue = "\(step.rawValue + 1) / 3"

        switch step {
        case .welcome:
            configureWelcomeStep()
        case .permission:
            configurePermissionStep()
            startPermissionTimer()
        case .wallpaper:
            configureWallpaperStep()
        }
    }

    private func configureWelcomeStep() {
        primaryButton.title = "开始设置"
        secondaryButton.isHidden = true

        let imageView = NSImageView()
        imageView.image = Bundle.main.image(forResource: "KrustyKrab")
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true

        let title = makeTitle("欢迎来到 Mijine Bar")
        let subtitle = makeBody("每次敲击键盘，收银机都会增加一点金额。\n它是一张会回应你的桌面，也可以记录计划和备忘。")
        installStack([imageView, title, subtitle], spacing: 16)
        imageView.heightAnchor.constraint(equalToConstant: 220).isActive = true
    }

    private func configurePermissionStep() {
        primaryButton.title = CGPreflightListenEventAccess() ? "继续" : "允许输入监控"
        secondaryButton.title = "暂时跳过"
        secondaryButton.isHidden = false

        let symbol = NSImageView(image: NSImage(
            systemSymbolName: "keyboard.badge.ellipsis",
            accessibilityDescription: "输入监控"
        ) ?? NSImage())
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 52, weight: .regular)
        symbol.contentTintColor = .controlAccentColor

        let title = makeTitle("允许读取“按键发生”")
        let subtitle = makeBody("Mijine Bar 需要知道你什么时候按下了键，才能更新收银机金额。")
        let privacy = makeBody("✓ 不读取你输入的文字\n✓ 不保存具体按键\n✓ 所有统计只保存在这台 Mac")
        privacy.textColor = .secondaryLabelColor

        permissionStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        permissionStatusLabel.alignment = .center
        permissionStatusLabel.maximumNumberOfLines = 0

        let settingsButton = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .linkColor
        settingsButton.isHidden = CGPreflightListenEventAccess()
        settingsButton.identifier = NSUserInterfaceItemIdentifier("permissionSettingsButton")

        installStack([symbol, title, subtitle, privacy, permissionStatusLabel, settingsButton], spacing: 14)
    }

    private func configureWallpaperStep() {
        primaryButton.title = "设为壁纸并开始"
        secondaryButton.title = "暂不设置"
        secondaryButton.isHidden = false

        let symbol = NSImageView(image: NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "桌面壁纸"
        ) ?? NSImage())
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 52, weight: .regular)
        symbol.contentTintColor = .controlAccentColor

        let title = makeTitle("准备好布置桌面了吗？")
        let subtitle = makeBody("Mijine Bar 会把蟹堡王设置为所有显示器的系统壁纸，并在桌面上显示动态金额和便签。")
        let note = makeBody("退出应用后，系统壁纸不会自动恢复。你可以随时在 macOS 系统设置中更换壁纸。")
        note.textColor = .secondaryLabelColor
        installStack([symbol, title, subtitle, note], spacing: 16)
    }

    private func installStack(_ views: [NSView], spacing: CGFloat) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(stack)

        for view in views where view is NSTextField {
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 500).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor)
        ])
    }

    private func makeTitle(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.alignment = .center
        return label
    }

    private func makeBody(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        return label
    }

    @objc private func performPrimaryAction() {
        switch step {
        case .welcome:
            show(step: .permission)
        case .permission:
            if CGPreflightListenEventAccess() {
                reportPermissionGrantedIfNeeded()
                show(step: .wallpaper)
            } else if !permissionRequestAttempted {
                permissionRequestAttempted = true
                if requestPermission() {
                    reportPermissionGrantedIfNeeded()
                    show(step: .wallpaper)
                } else {
                    updatePermissionUI()
                }
            } else {
                openInputSettings()
                updatePermissionUI()
            }
        case .wallpaper:
            finishOnboarding(applyWallpaper: true)
        }
    }

    @objc private func performSecondaryAction() {
        switch step {
        case .welcome:
            break
        case .permission:
            show(step: .wallpaper)
        case .wallpaper:
            finishOnboarding(applyWallpaper: false)
        }
    }

    @objc private func openSettings() {
        openInputSettings()
    }

    private func finishOnboarding(applyWallpaper: Bool) {
        stopPermissionTimer()
        window.orderOut(nil)
        finish(applyWallpaper)
    }

    private func startPermissionTimer() {
        updatePermissionUI()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePermissionUI()
            }
        }
    }

    private func stopPermissionTimer() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func updatePermissionUI() {
        let granted = CGPreflightListenEventAccess()
        if granted {
            primaryButton.title = "继续"
            permissionStatusLabel.stringValue = "✓ 输入监控已开启"
            permissionStatusLabel.textColor = .systemGreen
        } else if permissionRequestAttempted {
            primaryButton.title = "重新检查"
            permissionStatusLabel.stringValue = "系统尚未认可授权。请在系统设置中将 Mijine 的开关关闭后重新开启，再返回这里检查。"
            permissionStatusLabel.textColor = .systemOrange
        } else {
            primaryButton.title = "允许输入监控"
            permissionStatusLabel.stringValue = "点击后，macOS 会引导你前往“输入监控”设置。"
            permissionStatusLabel.textColor = .secondaryLabelColor
        }
        bodyContainer.subviews
            .flatMap(\.subviews)
            .first { $0.identifier?.rawValue == "permissionSettingsButton" }?
            .isHidden = granted
        if granted { reportPermissionGrantedIfNeeded() }
    }

    private func reportPermissionGrantedIfNeeded() {
        guard !reportedPermissionGranted else { return }
        reportedPermissionGranted = true
        permissionGranted()
    }
}
