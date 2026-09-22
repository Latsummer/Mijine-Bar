import AppKit
import CoreGraphics

@MainActor
final class KeyboardState {
    enum IncrementMode: String {
        case fixed
        case random
    }

    private enum StorageKey {
        static let day = "dailyCounter.day"
        static let cents = "dailyCounter.cents"
        static let incrementMode = "dailyCounter.incrementMode"
        static let fixedIncrementCents = "dailyCounter.fixedIncrementCents"
        static let randomMinimumCents = "dailyCounter.randomMinimumCents"
        static let randomMaximumCents = "dailyCounter.randomMaximumCents"
        static let resetsAtMidnight = "dailyCounter.resetsAtMidnight"
    }

    private let defaults = UserDefaults.standard
    private var observers: [WeakView] = []
    private var pressedCodes: Set<Int> = []
    private var storedDay = ""
    private var lastDayCheck = Date.distantPast

    private(set) var dailyCents = 0
    private(set) var displayPulse: CGFloat = 0
    private(set) var incrementMode: IncrementMode = .fixed
    private(set) var fixedIncrementCents = 1
    private(set) var randomMinimumCents = 1
    private(set) var randomMaximumCents = 100
    private(set) var resetsAtMidnight = true

    var hasInputPermission = false {
        didSet { notifyObservers() }
    }

    // The keyboard listener is global.  While a desktop note is being edited,
    // keep listening for key-up events but do not turn that writing into money.
    var isEditingNote = false

    init() {
        loadSettings()
        loadToday()
    }

    var amountText: String {
        String(format: "%.2f", Double(dailyCents) / 100.0)
    }

    var incrementDescription: String {
        switch incrementMode {
        case .fixed:
            return "固定 \(Self.format(cents: fixedIncrementCents))"
        case .random:
            return "随机 \(Self.format(cents: randomMinimumCents)) ～ \(Self.format(cents: randomMaximumCents))"
        }
    }

    func addObserver(_ view: KeyboardWallpaperView) {
        observers.append(WeakView(view))
    }

    func setKey(code: Int, isDown: Bool, shouldCount: Bool) {
        refreshDayIfNeeded()
        let wasPressed = pressedCodes.contains(code)
        if isDown {
            pressedCodes.insert(code)
        } else {
            pressedCodes.remove(code)
        }

        if shouldCount && !isEditingNote && (!wasPressed || code == 57) {
            let increment: Int
            switch incrementMode {
            case .fixed:
                increment = fixedIncrementCents
            case .random:
                increment = Int.random(in: randomMinimumCents...randomMaximumCents)
            }
            let result = dailyCents.addingReportingOverflow(increment)
            dailyCents = result.overflow ? Int.max : result.partialValue
            displayPulse = 1
            persist()
        }
        notifyObservers()
    }

    func advanceAnimation() {
        var changed = false
        if displayPulse > 0.01 {
            displayPulse *= 0.88
            changed = true
        } else if displayPulse != 0 {
            displayPulse = 0
            changed = true
        }

        if Date().timeIntervalSince(lastDayCheck) >= 1 {
            changed = refreshDayIfNeeded() || changed
        }
        if changed { notifyObservers() }
    }

    func useFixedIncrement(cents: Int) {
        guard cents >= 1 else { return }
        incrementMode = .fixed
        fixedIncrementCents = cents
        persistSettings()
    }

    func useRandomIncrement(minimumCents: Int, maximumCents: Int) {
        guard minimumCents >= 1, maximumCents >= minimumCents, maximumCents <= 100 else { return }
        incrementMode = .random
        randomMinimumCents = minimumCents
        randomMaximumCents = maximumCents
        persistSettings()
    }

    func setResetsAtMidnight(_ enabled: Bool) {
        resetsAtMidnight = enabled
        persistSettings()
    }

    func resetAmount() {
        dailyCents = 0
        displayPulse = 1
        persist()
        notifyObservers()
    }

    private func loadSettings() {
        incrementMode = IncrementMode(rawValue: defaults.string(forKey: StorageKey.incrementMode) ?? "") ?? .fixed
        fixedIncrementCents = max(1, defaults.object(forKey: StorageKey.fixedIncrementCents) == nil ? 1 : defaults.integer(forKey: StorageKey.fixedIncrementCents))
        randomMinimumCents = min(100, max(1, defaults.object(forKey: StorageKey.randomMinimumCents) == nil ? 1 : defaults.integer(forKey: StorageKey.randomMinimumCents)))
        randomMaximumCents = min(100, max(randomMinimumCents, defaults.object(forKey: StorageKey.randomMaximumCents) == nil ? 100 : defaults.integer(forKey: StorageKey.randomMaximumCents)))
        resetsAtMidnight = defaults.object(forKey: StorageKey.resetsAtMidnight) == nil ? true : defaults.bool(forKey: StorageKey.resetsAtMidnight)
    }

    private func persistSettings() {
        defaults.set(incrementMode.rawValue, forKey: StorageKey.incrementMode)
        defaults.set(fixedIncrementCents, forKey: StorageKey.fixedIncrementCents)
        defaults.set(randomMinimumCents, forKey: StorageKey.randomMinimumCents)
        defaults.set(randomMaximumCents, forKey: StorageKey.randomMaximumCents)
        defaults.set(resetsAtMidnight, forKey: StorageKey.resetsAtMidnight)
    }

    private func loadToday() {
        let today = Self.dayIdentifier(for: Date())
        storedDay = defaults.string(forKey: StorageKey.day) ?? ""
        if storedDay == today {
            dailyCents = defaults.integer(forKey: StorageKey.cents)
        } else {
            storedDay = today
            dailyCents = 0
            persist()
        }
        lastDayCheck = Date()
    }

    @discardableResult
    private func refreshDayIfNeeded() -> Bool {
        lastDayCheck = Date()
        let today = Self.dayIdentifier(for: lastDayCheck)
        guard today != storedDay else { return false }

        storedDay = today
        if resetsAtMidnight {
            dailyCents = 0
            displayPulse = 1
        }
        persist()
        return true
    }

    private func persist() {
        defaults.set(storedDay, forKey: StorageKey.day)
        defaults.set(dailyCents, forKey: StorageKey.cents)
    }

    private static func dayIdentifier(for date: Date) -> String {
        let values = Calendar.current.dateComponents([.era, .year, .month, .day], from: date)
        return "\(values.era ?? 0)-\(values.year ?? 0)-\(values.month ?? 0)-\(values.day ?? 0)"
    }

    private static func format(cents: Int) -> String {
        String(format: "%.2f", Double(cents) / 100.0)
    }

    private func notifyObservers() {
        observers.removeAll { $0.value == nil }
        observers.forEach { $0.value?.needsDisplay = true }
    }
}

@MainActor
private final class WeakView {
    weak var value: KeyboardWallpaperView?
    init(_ value: KeyboardWallpaperView) { self.value = value }
}

private extension NSPoint {
    func distance(to other: NSPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }

    func interpolated(toward target: NSPoint, factor: CGFloat) -> NSPoint {
        NSPoint(
            x: x + (target.x - x) * factor,
            y: y + (target.y - y) * factor
        )
    }
}

@MainActor
final class WallpaperController {
    private let state: KeyboardState
    private var windows: [NSWindow] = []
    private let notes = NotesStore()
    private var noteControllers: [DesktopNoteController] = []

    init(state: KeyboardState) {
        self.state = state
    }

    func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        noteControllers.forEach { $0.close() }
        noteControllers.removeAll()

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            // Let the window participate in the system's Space transition. Using
            // `.stationary` here makes the wallpaper remain pinned while the real
            // desktop slides, which causes a visible pop at the end of a swipe.
            window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
            window.animationBehavior = .none
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.canHide = false
            window.hidesOnDeactivate = false

            let view = KeyboardWallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size), state: state)
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)

            for kind in DesktopNoteKind.allCases {
                let controller = DesktopNoteController(
                    kind: kind,
                    screen: screen,
                    state: state,
                    store: notes
                )
                noteControllers.append(controller)
            }
        }
    }

    func toggleNote(_ kind: DesktopNoteKind) {
        // On a multi-display setup, opening the note on the primary display is
        // less surprising than opening several editable cards at once.
        let controller = noteControllers.first { $0.kind == kind && $0.screen == NSScreen.main }
            ?? noteControllers.first { $0.kind == kind }
        controller?.toggle()
    }

    func handleGlobalMouseDown(at location: NSPoint) {
        // Never let a click on one of our open cards fall through to a sign
        // that happens to sit behind it.
        guard !noteControllers.contains(where: { $0.expandedCardContains(location) }) else { return }
        guard let controller = noteControllers.first(where: { $0.containsSign(location) }) else { return }

        // The event tap is global, so coordinates alone are not enough: an app
        // window may currently cover the artwork at this point. Only treat the
        // click as a sign click when the desktop is actually exposed there.
        guard isDesktopVisible(at: location) else { return }
        controller.toggleFromGlobalClick()
    }

    private func isDesktopVisible(at cocoaPoint: NSPoint) -> Bool {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        // CGWindow bounds use a top-left origin while NSEvent.mouseLocation
        // uses Cocoa's bottom-left global coordinates.
        let mainScreenTop = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        let quartzPoint = CGPoint(x: cocoaPoint.x, y: mainScreenTop - cocoaPoint.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for info in windowInfo {
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            if ownerPID == ownPID { continue }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            // Real application document windows are on layer 0. macOS also
            // maintains transparent, screen-sized Dock/WindowManager surfaces
            // on higher layers; treating those as blockers disables every sign.
            guard layer == 0 else { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { continue }
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }

            if bounds.contains(quartzPoint) {
                return false
            }
        }
        return true
    }
}

@MainActor
final class KeyboardWallpaperView: NSView {
    private struct Eye {
        let centerFromTop: NSPoint
        let whiteSize: NSSize
        let pupilRadius: CGFloat
        let maximumOffset: NSSize
    }

    // These points are measured against the 3840 × 2160 source artwork.
    private let cashierEyes = [
        Eye(centerFromTop: NSPoint(x: 1309, y: 687), whiteSize: NSSize(width: 112, height: 115), pupilRadius: 19, maximumOffset: NSSize(width: 24, height: 26)),
        Eye(centerFromTop: NSPoint(x: 1437, y: 688), whiteSize: NSSize(width: 120, height: 117), pupilRadius: 19, maximumOffset: NSSize(width: 25, height: 26))
    ]

    private let state: KeyboardState
    private let wallpaper: NSImage?
    private var timer: Timer?
    private var lastMouseLocation = NSEvent.mouseLocation
    private var lastMouseMovement = Date()
    private var eyeOffsets: [NSPoint] = [.zero, .zero]

    init(frame frameRect: NSRect, state: KeyboardState) {
        self.state = state
        if let url = Bundle.main.url(forResource: "KrustyKrab", withExtension: "jpg") {
            wallpaper = NSImage(contentsOf: url)
        } else {
            wallpaper = nil
        }
        super.init(frame: frameRect)
        state.addObserver(self)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 50.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceAnimation() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        bounds.fill()

        guard let wallpaper else {
            drawMissingWallpaperMessage()
            return
        }

        let imageRect = aspectFillRect(imageSize: wallpaper.size, container: bounds)
        wallpaper.draw(
            in: imageRect,
            from: NSRect(origin: .zero, size: wallpaper.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        drawNoteAffordances(in: imageRect)
        drawFollowingEyes(in: imageRect)
        drawAmount(in: imageRect)
        drawPermissionMessageIfNeeded()
    }

    private func aspectFillRect(imageSize: NSSize, container: NSRect) -> NSRect {
        let scale = max(container.width / imageSize.width, container.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func advanceAnimation() {
        state.advanceAnimation()

        let mouseLocation = NSEvent.mouseLocation
        if mouseLocation.distance(to: lastMouseLocation) > 0.5 {
            lastMouseLocation = mouseLocation
            lastMouseMovement = Date()
        }

        let shouldReturnToCenter = Date().timeIntervalSince(lastMouseMovement) >= 6
        let imageRect = aspectFillRect(imageSize: wallpaper?.size ?? bounds.size, container: bounds)
        let targetOffsets = cashierEyes.map { eye in
            shouldReturnToCenter ? .zero : eyeOffset(for: eye, imageRect: imageRect, mouseLocation: mouseLocation)
        }

        var didChange = false
        for index in eyeOffsets.indices {
            let next = eyeOffsets[index].interpolated(toward: targetOffsets[index], factor: 0.14)
            if next.distance(to: eyeOffsets[index]) > 0.01 {
                eyeOffsets[index] = next
                didChange = true
            }
        }
        if didChange { needsDisplay = true }
    }

    private func drawFollowingEyes(in imageRect: NSRect) {
        let scale = imageRect.width / 3840
        for (index, eye) in cashierEyes.enumerated() {
            let center = imagePoint(eye.centerFromTop, in: imageRect)
            let whiteRect = NSRect(
                x: center.x - eye.whiteSize.width * scale / 2,
                y: center.y - eye.whiteSize.height * scale / 2,
                width: eye.whiteSize.width * scale,
                height: eye.whiteSize.height * scale
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: whiteRect).fill()

            let offset = eyeOffsets[index]
            let radius = eye.pupilRadius * scale
            let pupilRect = NSRect(
                x: center.x + offset.x - radius,
                y: center.y + offset.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: pupilRect).fill()
        }
    }

    private func eyeOffset(for eye: Eye, imageRect: NSRect, mouseLocation: NSPoint) -> NSPoint {
        guard let window else { return .zero }
        let mouseInWindow = window.convertPoint(fromScreen: mouseLocation)
        let center = imagePoint(eye.centerFromTop, in: imageRect)
        let direction = NSPoint(x: mouseInWindow.x - center.x, y: mouseInWindow.y - center.y)
        let distance = hypot(direction.x, direction.y)
        guard distance > 0.1 else { return .zero }

        let scale = imageRect.width / 3840
        return NSPoint(
            x: direction.x / distance * eye.maximumOffset.width * scale,
            y: direction.y / distance * eye.maximumOffset.height * scale
        )
    }

    private func imagePoint(_ pointFromTop: NSPoint, in imageRect: NSRect) -> NSPoint {
        NSPoint(
            x: imageRect.minX + imageRect.width * pointFromTop.x / 3840,
            y: imageRect.minY + imageRect.height * (2160 - pointFromTop.y) / 2160
        )
    }

    private func drawNoteAffordances(in imageRect: NSRect) {
        let scale = imageRect.width / 3840
        let labels: [(DesktopNoteKind, String, NSColor)] = [
            (.daily, "日常记录  ▼", NSColor(calibratedRed: 0.42, green: 0.95, blue: 0.45, alpha: 1)),
            (.plan, "今日计划  ▼", NSColor(calibratedRed: 0.52, green: 1.00, blue: 0.70, alpha: 1)),
            (.memo, "随手备忘  ▼", NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.30, alpha: 1))
        ]

        for (kind, label, accent) in labels {
            let sign = kind.sourceRect
            let width: CGFloat = 230
            let height: CGFloat = 58
            let sourcePill = NSRect(
                x: sign.midX - width / 2,
                y: sign.maxY - 4,
                width: width,
                height: height
            )
            let pill = NSRect(
                x: imageRect.minX + sourcePill.minX * scale,
                y: imageRect.minY + (2160 - sourcePill.maxY) * scale,
                width: sourcePill.width * scale,
                height: sourcePill.height * scale
            )

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = accent.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = max(5, 13 * scale)
            shadow.shadowOffset = .zero
            shadow.set()
            NSColor.black.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()

            accent.withAlphaComponent(0.95).setStroke()
            let outline = NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1), xRadius: pill.height / 2, yRadius: pill.height / 2)
            outline.lineWidth = max(1.2, 3 * scale)
            outline.stroke()

            let text = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: max(10, 27 * scale), weight: .bold),
                    .foregroundColor: NSColor.white
                ]
            )
            let textSize = text.size()
            text.draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2 + 1))
        }
    }

    private func drawAmount(in imageRect: NSRect) {
        // Coordinates are normalized against the original 3840 × 2160 artwork.
        let displayRect = NSRect(
            x: imageRect.minX + imageRect.width * (1888.0 / 3840.0),
            y: imageRect.minY + imageRect.height * ((2160.0 - 1295.0) / 2160.0),
            width: imageRect.width * (335.0 / 3840.0),
            height: imageRect.height * (99.0 / 2160.0)
        )

        let screenPath = NSBezierPath(
            roundedRect: displayRect,
            xRadius: displayRect.height * 0.07,
            yRadius: displayRect.height * 0.07
        )
        NSColor(calibratedRed: 0.003, green: 0.012, blue: 0.013, alpha: 0.98).setFill()
        screenPath.fill()
        NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.15, alpha: 0.8).setStroke()
        screenPath.lineWidth = max(0.7, displayRect.height * 0.018)
        screenPath.stroke()

        let inset = displayRect.insetBy(dx: displayRect.width * 0.035, dy: displayRect.height * 0.13)
        drawSevenSegmentText(state.amountText, in: inset)
    }

    private func drawSevenSegmentText(_ text: String, in rect: NSRect) {
        let digitCount = CGFloat(text.filter(\.isNumber).count)
        let dotCount = CGFloat(text.filter { $0 == "." }.count)
        let digitUnit: CGFloat = 0.52
        let dotUnit: CGFloat = 0.17
        let gapUnit: CGFloat = 0.08
        let totalUnits = digitCount * digitUnit + dotCount * dotUnit + CGFloat(max(0, text.count - 1)) * gapUnit
        let digitHeight = min(rect.height, rect.width / totalUnits)
        let digitWidth = digitHeight * digitUnit
        let dotWidth = digitHeight * dotUnit
        let gap = digitHeight * gapUnit
        let totalWidth = digitCount * digitWidth + dotCount * dotWidth + CGFloat(max(0, text.count - 1)) * gap
        var x = rect.maxX - totalWidth
        let y = rect.midY - digitHeight / 2

        let pulse = state.displayPulse
        let color = NSColor(
            calibratedRed: 0.50 + 0.22 * pulse,
            green: 1,
            blue: 0.35 + 0.25 * pulse,
            alpha: 1
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.55 + 0.35 * pulse)
        shadow.shadowBlurRadius = digitHeight * (0.07 + 0.07 * pulse)
        shadow.set()
        color.setFill()

        for character in text {
            if character == "." {
                let diameter = digitHeight * 0.13
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
                x += dotWidth + gap
            } else {
                drawDigit(character, in: NSRect(x: x, y: y, width: digitWidth, height: digitHeight))
                x += digitWidth + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDigit(_ character: Character, in rect: NSRect) {
        let active: Set<Character>
        switch character {
        case "0": active = ["a", "b", "c", "d", "e", "f"]
        case "1": active = ["b", "c"]
        case "2": active = ["a", "b", "g", "e", "d"]
        case "3": active = ["a", "b", "c", "d", "g"]
        case "4": active = ["f", "g", "b", "c"]
        case "5": active = ["a", "f", "g", "c", "d"]
        case "6": active = ["a", "f", "g", "e", "c", "d"]
        case "7": active = ["a", "b", "c"]
        case "8": active = ["a", "b", "c", "d", "e", "f", "g"]
        case "9": active = ["a", "b", "c", "d", "f", "g"]
        default: active = []
        }

        let thickness = rect.width * 0.17
        let radius = thickness * 0.45
        let horizontalWidth = rect.width - thickness * 1.15
        let verticalHeight = rect.height / 2 - thickness * 1.25
        let segments: [Character: NSRect] = [
            "a": NSRect(x: rect.minX + thickness * 0.58, y: rect.maxY - thickness, width: horizontalWidth, height: thickness),
            "g": NSRect(x: rect.minX + thickness * 0.58, y: rect.midY - thickness / 2, width: horizontalWidth, height: thickness),
            "d": NSRect(x: rect.minX + thickness * 0.58, y: rect.minY, width: horizontalWidth, height: thickness),
            "f": NSRect(x: rect.minX, y: rect.midY + thickness * 0.25, width: thickness, height: verticalHeight),
            "b": NSRect(x: rect.maxX - thickness, y: rect.midY + thickness * 0.25, width: thickness, height: verticalHeight),
            "e": NSRect(x: rect.minX, y: rect.minY + thickness, width: thickness, height: verticalHeight),
            "c": NSRect(x: rect.maxX - thickness, y: rect.minY + thickness, width: thickness, height: verticalHeight)
        ]

        for segment in active {
            if let segmentRect = segments[segment] {
                NSBezierPath(roundedRect: segmentRect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    private func drawPermissionMessageIfNeeded() {
        guard !state.hasInputPermission else { return }
        let message = "请允许 Mijine 的收银台使用输入监控，然后从菜单栏重试"
        let text = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        let size = text.size()
        let panel = NSRect(x: bounds.midX - size.width / 2 - 18, y: 32, width: size.width + 36, height: size.height + 18)
        NSColor(calibratedWhite: 0, alpha: 0.76).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 9, yRadius: 9).fill()
        text.draw(at: NSPoint(x: panel.minX + 18, y: panel.minY + 9))
    }

    private func drawMissingWallpaperMessage() {
        let message = "找不到 KrustyKrab.jpg 壁纸资源"
        let text = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
