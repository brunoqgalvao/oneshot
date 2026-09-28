import AppKit

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: AppController
    private let menu = NSMenu()

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        guard let button = item.button else { return }
        let (symbol, tint): (String, NSColor?) = {
            if controller.isRecording { return ("waveform.circle.fill", .systemRed) }
            if controller.inFlight > 0 { return ("ellipsis.circle", nil) }
            if !controller.hotkeyActive { return ("exclamationmark.triangle", nil) }
            return ("waveform", nil)
        }()
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        img?.isTemplate = true
        button.image = img
        button.contentTintColor = tint
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Prefs.shared

        let header = NSMenuItem(title: controller.hotkeyActive ? "Hold \(prefs.trigger.short) to dictate" : "Finish setup to start dictating", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !controller.hotkeyActive || AudioRecorder.permission != .authorized || prefs.effectiveAPIKey == nil && prefs.engine == .openAI {
            menu.addItem(make("Finish Setup…", #selector(openSetup)))
        }
        menu.addItem(.separator())
        menu.addItem(make(controller.isRecording ? "Stop Dictation" : "Start Dictation (hands-free)", #selector(toggle)))
        if !controller.isRecording { menu.addItem(make("Start Command…", #selector(command))) }
        if controller.canRetry { menu.addItem(make("Retry Last Failed", #selector(retry))) }
        let pasteLast = make("Paste Last Transcript", #selector(pasteLast))
        pasteLast.isEnabled = !HistoryStore.shared.items.isEmpty
        menu.addItem(pasteLast)

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let items = HistoryStore.shared.items.prefix(10)
        if items.isEmpty {
            let none = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for d in items {
            let flat = d.text.replacingOccurrences(of: "\n", with: " ")
            let title = flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
            let mi = NSMenuItem(title: title, action: #selector(copyItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = d.text
            mi.toolTip = "Click to copy · \(d.app ?? "")"
            sub.addItem(mi)
        }
        recent.submenu = sub
        menu.addItem(recent)

        menu.addItem(.separator())
        menu.addItem(make("Settings…", #selector(openSettings), key: ","))
        menu.addItem(make("Quit Murmur", #selector(quit), key: "q"))
    }

    private func make(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func toggle() { controller.toggle() }
    @objc private func command() { controller.startCommand() }
    @objc private func retry() { controller.retryLast() }
    @objc private func pasteLast() { controller.pasteLast() }
    @objc private func openSettings() { controller.openSettings?("general") }
    @objc private func openSetup() { controller.openSettings?("setup") }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func copyItem(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String { Paster.copy(s) }
    }
}
