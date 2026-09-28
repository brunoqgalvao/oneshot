import AppKit
import Carbon.HIToolbox

/// Global keyboard listener built on a CGEventTap. Reports presses/releases of
/// a single modifier key (fn, right ⌥, right ⌘) and lets the controller
/// consume Space (lock hands-free) and Esc (cancel) while dictating.
final class HotkeyMonitor {
    var trigger: TriggerKey = .fn

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Return true to swallow the key.
    var onSpaceWhileHeld: (() -> Bool)?
    var onEscape: (() -> Bool)?
    /// Another key was typed while the trigger was held (e.g. fn+←, ⌥+e).
    var onOtherKeyWhileHeld: (() -> Void)?
    var onControlDown: (() -> Void)?

    private(set) var isTriggerDown = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeyUps = Set<Int64>()

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            }, userInfo: me) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; isTriggerDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Paster.eventTag { return pass }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            if code == trigger.keyCode {
                let down = event.flags.contains(trigger.flag)
                if down != isTriggerDown {
                    isTriggerDown = down
                    down ? onPress?() : onRelease?()
                }
            } else if code == Int64(kVK_Control) || code == Int64(kVK_RightControl) {
                if event.flags.contains(.maskControl) { onControlDown?() }
            }
            return pass
        case .keyDown:
            if code == Int64(kVK_Escape), onEscape?() == true {
                swallowedKeyUps.insert(code); return nil
            }
            if code == Int64(kVK_Space), isTriggerDown, onSpaceWhileHeld?() == true {
                swallowedKeyUps.insert(code); return nil
            }
            if isTriggerDown { onOtherKeyWhileHeld?() }
            return pass
        case .keyUp:
            if swallowedKeyUps.remove(code) != nil { return nil }
            return pass
        default:
            return pass
        }
    }
}
