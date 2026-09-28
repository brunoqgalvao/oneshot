import AppKit
import ApplicationServices

/// What the user was typing into when dictation started, read through the
/// Accessibility API. Every field is optional: many apps expose little.
struct FocusSnapshot {
    var appName: String?
    var bundleID: String?
    var pid: pid_t?
    var windowTitle: String?
    var role: String?
    var isSecure = false
    var textBeforeCursor: String?
    var selectedText: String?

    var destination: Destination { Destination.classify(bundleID: bundleID, appName: appName, windowTitle: windowTitle) }

    static func capture(readText: Bool) -> FocusSnapshot {
        var s = FocusSnapshot()
        let app = NSWorkspace.shared.frontmostApplication
        s.appName = app?.localizedName
        s.bundleID = app?.bundleIdentifier
        s.pid = app?.processIdentifier
        guard AXIsProcessTrusted(), let pid = s.pid else { return s }

        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.2)
        if let win: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) {
            s.windowTitle = attr(win, kAXTitleAttribute)
        }
        guard let el: AXUIElement = attr(appEl, kAXFocusedUIElementAttribute) else { return s }
        AXUIElementSetMessagingTimeout(el, 0.2)
        s.role = attr(el, kAXRoleAttribute)
        let subrole: String? = attr(el, kAXSubroleAttribute)
        s.isSecure = subrole == (kAXSecureTextFieldSubrole as String)
        guard readText, !s.isSecure else { return s }

        s.selectedText = attr(el, kAXSelectedTextAttribute)
        if let value: String = attr(el, kAXValueAttribute),
           let rangeValue: AXValue = attr(el, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                let ns = value as NSString
                let loc = max(0, min(range.location, ns.length))
                let start = max(0, loc - 600)
                s.textBeforeCursor = ns.substring(with: NSRange(location: start, length: loc - start))
            }
        }
        return s
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }
}
