import AppKit
import CoreGraphics
import Foundation

final class InputMonitor {
    typealias Handler = (_ keyCode: Int, _ isDown: Bool, _ shouldCount: Bool) -> Void
    typealias MouseHandler = (_ location: CGPoint, _ buttonNumber: Int) -> Void

    private let handler: Handler
    private let mouseHandler: MouseHandler?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    init(handler: @escaping Handler, mouseHandler: MouseHandler? = nil) {
        self.handler = handler
        self.mouseHandler = mouseHandler
    }

    deinit {
        stop()
    }

    @discardableResult
    func start(requestPermission: Bool) -> Bool {
        stop()

        var trusted = CGPreflightListenEventAccess()
        if !trusted && requestPermission {
            trusted = CGRequestListenEventAccess()
        }

        guard trusted else {
            isRunning = false
            return false
        }

        let interestedEvents = [
            CGEventType.keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown
        ]
        let mask = interestedEvents.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                // CGEvent uses a top-left origin; Cocoa's mouse location already
                // matches the bottom-left screen coordinates used by NSWindow.
                let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                DispatchQueue.main.async {
                    monitor.mouseHandler?(NSEvent.mouseLocation, buttonNumber)
                }
                return Unmanaged.passUnretained(event)
            }

            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isDown: Bool
            let shouldCount: Bool
            switch type {
            case .keyDown:
                isDown = true
                shouldCount = true
            case .keyUp:
                isDown = false
                shouldCount = false
            case .flagsChanged:
                isDown = InputMonitor.modifierIsDown(keyCode: keyCode, flags: event.flags)
                // Caps Lock reports its new toggle state, so both transitions are presses.
                shouldCount = keyCode == 57 || isDown
            default:
                return Unmanaged.passUnretained(event)
            }

            DispatchQueue.main.async {
                monitor.handler(keyCode, isDown, shouldCount)
            }
            return Unmanaged.passUnretained(event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            isRunning = false
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    private static func modifierIsDown(keyCode: Int, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 57: return flags.contains(.maskAlphaShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }
}
