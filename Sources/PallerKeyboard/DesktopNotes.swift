import AppKit

@MainActor
enum DesktopNoteKind: String, CaseIterable {
    case daily
    case plan
    case memo

    var menuTitle: String {
        switch self {
        case .daily: "打开日常记录"
        case .plan: "打开今日计划"
        case .memo: "打开随手备忘"
        }
    }

    var title: String {
        switch self {
        case .daily: "日常记录"
        case .plan: "今日计划"
        case .memo: "随手备忘"
        }
    }

    // Measured from the 3840 × 2160 artwork, with its origin at the top left.
    var sourceRect: NSRect {
        switch self {
        case .daily: NSRect(x: 1495, y: 55, width: 325, height: 205)
        case .plan: NSRect(x: 1830, y: 50, width: 440, height: 220)
        case .memo: NSRect(x: 2235, y: 50, width: 300, height: 375)
        }
    }

    var cardHeight: CGFloat {
        switch self {
        case .daily: 350
        case .plan, .memo: 315
        }
    }
}

@MainActor
final class NotesStore {
    enum Lifetime: String, Codable {
        case persistent
        case todayOnly

        var label: String {
            switch self {
            case .persistent: "长期展示"
            case .todayOnly: "仅当天"
            }
        }
    }

    struct DailyTask: Codable, Identifiable {
        let id: UUID
        var title: String
        var isComplete: Bool
        var lifetime: Lifetime
        let createdDay: String
    }

    private struct SavedNotes: Codable {
        var dailyTasks: [DailyTask]
        var planText: String
        var memoText: String
    }

    private enum StorageKey {
        static let notes = "desktopNotes.v1"
        static func pinned(_ kind: DesktopNoteKind) -> String { "desktopNotes.pinned.\(kind.rawValue)" }
    }

    private let defaults = UserDefaults.standard
    private var observers: [UUID: () -> Void] = [:]
    private var saved: SavedNotes

    init() {
        if let data = defaults.data(forKey: StorageKey.notes),
           let decoded = try? JSONDecoder().decode(SavedNotes.self, from: data) {
            saved = decoded
        } else {
            saved = SavedNotes(dailyTasks: [], planText: "", memoText: "")
        }
    }

    var visibleDailyTasks: [DailyTask] {
        let today = Self.dayIdentifier(for: Date())
        return saved.dailyTasks.filter { $0.lifetime == .persistent || $0.createdDay == today }
    }

    var planText: String { saved.planText }
    var memoText: String { saved.memoText }

    func addDailyTask(title: String, lifetime: Lifetime) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        saved.dailyTasks.append(DailyTask(
            id: UUID(), title: cleanTitle, isComplete: false,
            lifetime: lifetime, createdDay: Self.dayIdentifier(for: Date())
        ))
        persistAndNotify()
    }

    func toggleTask(_ id: UUID) {
        guard let index = saved.dailyTasks.firstIndex(where: { $0.id == id }) else { return }
        saved.dailyTasks[index].isComplete.toggle()
        persistAndNotify()
    }

    func setLifetime(_ lifetime: Lifetime, for id: UUID) {
        guard let index = saved.dailyTasks.firstIndex(where: { $0.id == id }) else { return }
        saved.dailyTasks[index].lifetime = lifetime
        persistAndNotify()
    }

    func removeTask(_ id: UUID) {
        saved.dailyTasks.removeAll { $0.id == id }
        persistAndNotify()
    }

    func setText(_ text: String, for kind: DesktopNoteKind) {
        switch kind {
        case .plan: saved.planText = text
        case .memo: saved.memoText = text
        case .daily: return
        }
        persist()
    }

    func isPinned(_ kind: DesktopNoteKind) -> Bool {
        defaults.bool(forKey: StorageKey.pinned(kind))
    }

    func setPinned(_ pinned: Bool, for kind: DesktopNoteKind) {
        defaults.set(pinned, forKey: StorageKey.pinned(kind))
    }

    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func persistAndNotify() {
        persist()
        observers.values.forEach { $0() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: StorageKey.notes)
    }

    private static func dayIdentifier(for date: Date) -> String {
        let values = Calendar.current.dateComponents([.era, .year, .month, .day], from: date)
        return "\(values.era ?? 0)-\(values.year ?? 0)-\(values.month ?? 0)-\(values.day ?? 0)"
    }
}

@MainActor
private final class DesktopNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopNoteController: NSObject, NSWindowDelegate {
    let kind: DesktopNoteKind
    let screen: NSScreen

    private let state: KeyboardState
    private let store: NotesStore
    private let panel: DesktopNotePanel
    private let compactFrame: NSRect
    private let expandedFrame: NSRect
    private var hotspotView: NoteHotspotView!
    private var cardView: NoteCardView?
    private var observerID: UUID?
    private var isExpanded = false
    private var isPinned: Bool

    private static let desktopNoteLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2
    )

    init(kind: DesktopNoteKind, screen: NSScreen, state: KeyboardState, store: NotesStore) {
        self.kind = kind
        self.screen = screen
        self.state = state
        self.store = store
        self.compactFrame = Self.frame(for: kind.sourceRect, on: screen)
        self.expandedFrame = Self.cardFrame(for: kind, compactFrame: compactFrame, screen: screen)
        self.isPinned = store.isPinned(kind)
        self.panel = DesktopNotePanel(
            contentRect: compactFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        super.init()

        panel.level = Self.desktopNoteLevel
        // `.stationary` keeps this desktop accessory out of macOS's
        // "click wallpaper to reveal desktop" / Expose displacement animation.
        // Unlike the full-screen wallpaper window, a stationary note is exactly
        // what we want: it stays anchored beneath its sign while remaining key.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        installHotspot()
        observerID = store.addObserver { [weak self] in self?.cardView?.refresh() }
        panel.orderFrontRegardless()

        if isPinned {
            expand(activate: false)
        }
    }

    func close() {
        if let observerID { store.removeObserver(observerID) }
        panel.orderOut(nil)
        panel.close()
    }

    func toggle() {
        isExpanded ? collapse() : expand(activate: true)
    }

    func containsSign(_ point: NSPoint) -> Bool {
        compactFrame.contains(point)
    }

    func expandedCardContains(_ point: NSPoint) -> Bool {
        isExpanded && expandedFrame.contains(point)
    }

    func toggleFromGlobalClick() {
        // A click may also reach NoteHotspotView.  Deferring lets that normal
        // AppKit click win first and prevents the same click toggling twice.
        let wasExpanded = isExpanded
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isExpanded == wasExpanded else { return }
            self.toggle()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if isExpanded { state.isEditingNote = true }
    }

    func windowDidResignKey(_ notification: Notification) {
        state.isEditingNote = false
        // Pop-up buttons and macOS's "click wallpaper to reveal desktop"
        // briefly move key-window focus away from this panel.  Treating that
        // as an outside click made the note disappear while it was being used.
        // Notes now collapse only through the explicit button or sign toggle.
    }

    private func expand(activate: Bool) {
        guard !isExpanded else { return }
        isExpanded = true
        // Windows at the desktop level can be drawn but Finder owns the mouse
        // surface above them. Raise only the expanded card to a normal app
        // window so its fields, menus and buttons receive real input.
        panel.level = .normal
        panel.hasShadow = true
        let card = NoteCardView(
            kind: kind,
            store: store,
            pinned: isPinned,
            onClose: { [weak self] in self?.collapse() },
            onPinnedChanged: { [weak self] pinned in self?.setPinned(pinned) }
        )
        cardView = card
        panel.contentView = card
        panel.setFrame(expandedFrame, display: true, animate: true)
        panel.orderFrontRegardless()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            state.isEditingNote = true
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        state.isEditingNote = false
        isExpanded = false
        panel.level = Self.desktopNoteLevel
        panel.hasShadow = false
        panel.setFrame(compactFrame, display: true, animate: true)
        installHotspot()
        panel.orderFrontRegardless()
    }

    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        store.setPinned(pinned, for: kind)
        cardView?.setPinned(pinned)
    }

    private func installHotspot() {
        let hotspot = NoteHotspotView(frame: NSRect(origin: .zero, size: compactFrame.size))
        hotspot.onClick = { [weak self] in self?.expand(activate: true) }
        hotspotView = hotspot
        cardView = nil
        panel.contentView = hotspot
    }

    private static func frame(for sourceRect: NSRect, on screen: NSScreen) -> NSRect {
        let screenRect = NSRect(origin: .zero, size: screen.frame.size)
        let scale = max(screenRect.width / 3840.0, screenRect.height / 2160.0)
        let imageSize = NSSize(width: 3840.0 * scale, height: 2160.0 * scale)
        let imageRect = NSRect(
            x: (screenRect.width - imageSize.width) / 2,
            y: (screenRect.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        let local = NSRect(
            x: imageRect.minX + sourceRect.minX * scale,
            y: imageRect.minY + (2160.0 - sourceRect.maxY) * scale,
            width: sourceRect.width * scale,
            height: sourceRect.height * scale
        )
        return local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    private static func cardFrame(for kind: DesktopNoteKind, compactFrame: NSRect, screen: NSScreen) -> NSRect {
        let width = min(390, max(285, compactFrame.width * 0.9))
        let height = min(kind.cardHeight, max(315, screen.frame.height * 0.38))
        let desiredX = compactFrame.midX - width / 2
        let x = min(max(screen.frame.minX + 14, desiredX), screen.frame.maxX - width - 14)
        let desiredY = compactFrame.minY - height - 8
        let y = max(screen.frame.minY + 14, desiredY)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
private final class NoteHotspotView: NSView {
    var onClick: (() -> Void)?
    private var isHovering = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovering else { return }
        NSColor.white.withAlphaComponent(0.48).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
        path.lineWidth = 3
        path.stroke()
    }
}

@MainActor
private final class NoteCardView: NSView, NSTextViewDelegate {
    private let kind: DesktopNoteKind
    private let store: NotesStore
    private let titleLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private let closeButton = NSButton()
    private let helperLabel = NSTextField(labelWithString: "")
    private let onClose: () -> Void
    private let onPinnedChanged: (Bool) -> Void
    private var pinned: Bool

    private var textScrollView: NSScrollView?
    private var textView: NSTextView?
    private var taskScrollView: NSScrollView?
    private var taskListView: DailyTaskListView?
    private var taskField: NSTextField?
    private var lifetimePicker: NSPopUpButton?
    private var addTaskButton: NSButton?

    init(kind: DesktopNoteKind, store: NotesStore, pinned: Bool, onClose: @escaping () -> Void, onPinnedChanged: @escaping (Bool) -> Void) {
        self.kind = kind
        self.store = store
        self.pinned = pinned
        self.onClose = onClose
        self.onPinnedChanged = onPinnedChanged
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.stringValue = kind == .daily ? "GALLEY GRUB  ·  今日订单" : "GALLEY GRUB  ·  \(kind.title)"
        titleLabel.font = NSFont(name: "Avenir Next Condensed Demi Bold", size: 16)
            ?? .systemFont(ofSize: 16, weight: .heavy)
        titleLabel.textColor = NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.76, alpha: 1)
        addSubview(titleLabel)

        configureHeaderButton(pinButton, symbol: "pin", help: "固定在桌面")
        pinButton.target = self
        pinButton.action = #selector(togglePinned)
        addSubview(pinButton)

        configureHeaderButton(closeButton, symbol: "chevron.up", help: "收起订单")
        closeButton.target = self
        closeButton.action = #selector(close)
        addSubview(closeButton)

        helperLabel.font = .systemFont(ofSize: 11, weight: .medium)
        helperLabel.textColor = NSColor(calibratedRed: 0.31, green: 0.25, blue: 0.15, alpha: 0.78)
        addSubview(helperLabel)

        switch kind {
        case .daily: configureDaily()
        case .plan, .memo: configureTextNote()
        }
        setPinned(pinned)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func draw(_ dirtyRect: NSRect) {
        let paper = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
        NSColor(calibratedRed: 1.00, green: 0.95, blue: 0.76, alpha: 0.99).setFill()
        paper.fill()

        NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.10, alpha: 0.95).setStroke()
        paper.lineWidth = 4
        paper.stroke()
        let innerOutline = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 6, yRadius: 6)
        NSColor(calibratedRed: 0.45, green: 0.31, blue: 0.13, alpha: 0.38).setStroke()
        innerOutline.lineWidth = 1.5
        innerOutline.stroke()

        let headerRect = NSRect(x: 3, y: bounds.maxY - 52, width: bounds.width - 6, height: 49)
        let header = NSBezierPath(roundedRect: headerRect, xRadius: 7, yRadius: 7)
        NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.20, alpha: 1).setFill()
        header.fill()
        NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.07, alpha: 0.95).setStroke()
        header.lineWidth = 2.5
        header.stroke()

        for x in [CGFloat(16), bounds.width - 16] {
            let rivet = NSRect(x: x - 3, y: bounds.maxY - 31, width: 6, height: 6)
            NSColor(calibratedRed: 0.80, green: 0.72, blue: 0.46, alpha: 1).setFill()
            NSBezierPath(ovalIn: rivet).fill()
            NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.13, alpha: 0.8).setStroke()
            NSBezierPath(ovalIn: rivet).stroke()
        }

        if kind == .daily {
            NSColor(calibratedRed: 0.46, green: 0.34, blue: 0.19, alpha: 0.12).setStroke()
            let lines = NSBezierPath()
            var y = bounds.maxY - 91
            while y > 62 {
                lines.move(to: NSPoint(x: 18, y: y))
                lines.line(to: NSPoint(x: bounds.maxX - 18, y: y))
                y -= 37
            }
            lines.lineWidth = 1
            lines.stroke()
        }
    }

    override func layout() {
        super.layout()
        let top = bounds.maxY
        titleLabel.frame = NSRect(x: 28, y: top - 36, width: max(80, bounds.width - 112), height: 22)
        closeButton.frame = NSRect(x: bounds.maxX - 40, y: top - 39, width: 27, height: 27)
        pinButton.frame = NSRect(x: bounds.maxX - 72, y: top - 39, width: 27, height: 27)

        switch kind {
        case .daily:
            taskScrollView?.frame = NSRect(x: 16, y: 88, width: bounds.width - 32, height: max(70, bounds.height - 148))
            if let scroll = taskScrollView {
                taskListView?.setViewportWidth(scroll.contentSize.width)
            }
            taskField?.frame = NSRect(x: 16, y: 46, width: bounds.width - 125, height: 31)
            lifetimePicker?.frame = NSRect(x: bounds.width - 103, y: 46, width: 87, height: 31)
            addTaskButton?.frame = NSRect(x: 16, y: 12, width: bounds.width - 32, height: 28)
        case .plan, .memo:
            helperLabel.frame = NSRect(x: 18, y: 15, width: bounds.width - 36, height: 17)
            textScrollView?.frame = NSRect(x: 14, y: 38, width: bounds.width - 28, height: max(80, bounds.height - 98))
        }
    }

    func refresh() {
        if kind == .daily { taskListView?.reload(store.visibleDailyTasks) }
    }

    func setPinned(_ pinned: Bool) {
        self.pinned = pinned
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: pinned ? "已固定" : "固定在桌面"
        )
        pinButton.state = pinned ? .on : .off
        pinButton.contentTintColor = pinned
            ? NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.20, alpha: 1)
            : NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.76, alpha: 0.92)
    }

    private func configureHeaderButton(_ button: NSButton, symbol: String, help: String) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.76, alpha: 0.92)
        button.toolTip = help
    }

    private func configureDaily() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let list = DailyTaskListView()
        list.onToggle = { [weak self] id in self?.store.toggleTask(id) }
        list.onLifetimeChanged = { [weak self] id, lifetime in self?.store.setLifetime(lifetime, for: id) }
        list.onRemove = { [weak self] id in self?.store.removeTask(id) }
        scroll.documentView = list
        addSubview(scroll)
        taskScrollView = scroll
        taskListView = list
        // Attach the document view before loading rows. Otherwise its
        // superview is still nil and the first layout is only one point wide.
        list.reload(store.visibleDailyTasks)

        let field = NSTextField()
        field.placeholderString = "新订单：写下一件要做的事"
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.usesSingleLineMode = true
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.58)
        field.textColor = NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.10, alpha: 1)
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.borderWidth = 1.5
        field.layer?.borderColor = NSColor(calibratedRed: 0.36, green: 0.30, blue: 0.17, alpha: 0.35).cgColor
        field.target = self
        field.action = #selector(addTask)
        addSubview(field)
        taskField = field

        let picker = NSPopUpButton()
        picker.addItems(withTitles: [NotesStore.Lifetime.persistent.label, NotesStore.Lifetime.todayOnly.label])
        picker.font = .systemFont(ofSize: 11)
        picker.bezelStyle = .recessed
        picker.contentTintColor = NSColor(calibratedRed: 0.13, green: 0.29, blue: 0.17, alpha: 1)
        addSubview(picker)
        lifetimePicker = picker

        let add = NSButton(title: "＋  加入今日订单", target: self, action: #selector(addTask))
        add.isBordered = false
        add.font = .systemFont(ofSize: 12, weight: .semibold)
        add.wantsLayer = true
        add.layer?.cornerRadius = 6
        add.layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.39, blue: 0.22, alpha: 1).cgColor
        add.contentTintColor = NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.76, alpha: 1)
        addSubview(add)
        addTaskButton = add
    }

    private func configureTextNote() {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView()
        text.isRichText = false
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 13)
        text.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        text.backgroundColor = NSColor.white.withAlphaComponent(0.55)
        text.delegate = self
        text.string = kind == .plan ? store.planText : store.memoText
        scroll.documentView = text
        addSubview(scroll)
        textScrollView = scroll
        textView = text
        helperLabel.stringValue = kind == .plan ? "写下今天的安排，会自动保存" : "随手写下想记的事，会自动保存"
    }

    @objc private func togglePinned() {
        onPinnedChanged(!pinned)
    }

    @objc private func close() { onClose() }

    @objc private func addTask() {
        guard let field = taskField else { return }
        let lifetime: NotesStore.Lifetime = lifetimePicker?.indexOfSelectedItem == 1 ? .todayOnly : .persistent
        store.addDailyTask(title: field.stringValue, lifetime: lifetime)
        field.stringValue = ""
        field.becomeFirstResponder()
    }

    func textDidChange(_ notification: Notification) {
        guard let textView, notification.object as? NSTextView === textView else { return }
        store.setText(textView.string, for: kind)
    }
}

@MainActor
private final class DailyTaskListView: NSView {
    var onToggle: ((UUID) -> Void)?
    var onLifetimeChanged: ((UUID, NotesStore.Lifetime) -> Void)?
    var onRemove: ((UUID) -> Void)?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        resizeRowsToVisibleWidth()
    }

    func reload(_ tasks: [NotesStore.DailyTask]) {
        subviews.forEach { $0.removeFromSuperview() }
        frame.size.width = visibleWidth
        for task in tasks {
            let row = DailyTaskRowView(task: task)
            row.onToggle = { [weak self] id in self?.onToggle?(id) }
            row.onLifetimeChanged = { [weak self] id, lifetime in self?.onLifetimeChanged?(id, lifetime) }
            row.onRemove = { [weak self] id in self?.onRemove?(id) }
            addSubview(row)
        }
        layoutRows(to: frame.width)
        needsLayout = true
    }

    func setViewportWidth(_ width: CGFloat) {
        resizeRows(to: max(1, width))
    }

    private var visibleWidth: CGFloat {
        max(1, enclosingScrollView?.contentSize.width ?? superview?.bounds.width ?? bounds.width)
    }

    private func resizeRowsToVisibleWidth() {
        resizeRows(to: visibleWidth)
    }

    private func resizeRows(to width: CGFloat) {
        if abs(frame.width - width) > 0.5 {
            frame.size.width = width
        }
        layoutRows(to: width)
    }

    private func layoutRows(to width: CGFloat) {
        var y: CGFloat = 0
        for case let row as DailyTaskRowView in subviews {
            let height = row.preferredHeight(for: width)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            row.needsLayout = true
            y += height
        }
        frame.size.height = max(34, y)
    }
}

@MainActor
private final class DailyTaskRowView: NSView {
    private let task: NotesStore.DailyTask
    var onToggle: ((UUID) -> Void)?
    var onLifetimeChanged: ((UUID, NotesStore.Lifetime) -> Void)?
    var onRemove: ((UUID) -> Void)?
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let lifetime = NSPopUpButton()
    private let remove = NSButton(title: "×", target: nil, action: nil)

    init(task: NotesStore.DailyTask) {
        self.task = task
        super.init(frame: .zero)
        checkbox.title = task.title
        checkbox.state = task.isComplete ? .on : .off
        checkbox.font = .systemFont(ofSize: 13, weight: task.isComplete ? .regular : .medium)
        checkbox.contentTintColor = NSColor(calibratedRed: 0.15, green: 0.42, blue: 0.22, alpha: 1)
        if task.isComplete {
            checkbox.attributedTitle = NSAttributedString(
                string: task.title,
                attributes: [
                    .font: checkbox.font ?? NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor(calibratedRed: 0.34, green: 0.31, blue: 0.22, alpha: 0.58),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ]
            )
        }
        checkbox.lineBreakMode = .byWordWrapping
        checkbox.cell?.wraps = true
        checkbox.target = self
        checkbox.action = #selector(toggle)
        addSubview(checkbox)

        lifetime.addItems(withTitles: ["长期", "仅今天"])
        lifetime.font = .systemFont(ofSize: 10)
        lifetime.bezelStyle = .recessed
        lifetime.contentTintColor = NSColor(calibratedRed: 0.28, green: 0.24, blue: 0.14, alpha: 0.82)
        lifetime.selectItem(at: task.lifetime == .persistent ? 0 : 1)
        lifetime.target = self
        lifetime.action = #selector(changeLifetime)
        addSubview(lifetime)

        remove.title = ""
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除订单")
        remove.imagePosition = .imageOnly
        remove.isBordered = false
        remove.contentTintColor = NSColor(calibratedRed: 0.63, green: 0.20, blue: 0.15, alpha: 0.82)
        remove.toolTip = "删除订单"
        remove.target = self
        remove.action = #selector(delete)
        addSubview(remove)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func layout() {
        super.layout()
        let controlY = max(4, (bounds.height - 25) / 2)
        remove.frame = NSRect(x: bounds.maxX - 27, y: controlY, width: 24, height: 25)
        lifetime.frame = NSRect(x: bounds.maxX - 88, y: controlY, width: 58, height: 24)
        checkbox.frame = NSRect(x: 0, y: 4, width: max(30, bounds.width - 93), height: bounds.height - 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedRed: 0.40, green: 0.31, blue: 0.18, alpha: 0.16).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 4, y: 0.5))
        separator.line(to: NSPoint(x: bounds.maxX - 4, y: 0.5))
        separator.lineWidth = 1
        separator.stroke()
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(30, width - 119)
        let font = checkbox.font ?? .systemFont(ofSize: 12)
        let textHeight = (task.title as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        return max(34, ceil(textHeight) + 12)
    }

    @objc private func toggle() { onToggle?(task.id) }
    @objc private func changeLifetime() { onLifetimeChanged?(task.id, lifetime.indexOfSelectedItem == 0 ? .persistent : .todayOnly) }
    @objc private func delete() { onRemove?(task.id) }
}
