import AppKit
import SwiftUI

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: AppController
    private let menu = NSMenu()
    private var pulse: Timer?

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    func refresh() {
        guard let button = item.button else { return }
        let symbol: String
        var tint: NSColor? = nil
        if controller.isRecording { symbol = "waveform"; tint = .systemRed }
        else if !controller.hotkeyActive { symbol = "waveform.slash" }
        else { symbol = "waveform" }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Oneshot")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        img?.isTemplate = true
        button.image = img
        button.contentTintColor = tint

        // Gentle breathing while a dictation is being processed.
        if controller.inFlight > 0 && !controller.isRecording {
            if pulse == nil {
                let start = Date()
                pulse = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak button] _ in
                    let t = Date().timeIntervalSince(start)
                    MainActor.assumeIsolated { button?.alphaValue = 0.55 + 0.45 * CGFloat((cos(t * 5) + 1) / 2) }
                }
            }
        } else {
            pulse?.invalidate(); pulse = nil
            button.alphaValue = 1
        }
    }

    /// For screenshots: opens the menu and closes it after a few seconds.
    func showBriefly(seconds: Double = 3) {
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.menu.cancelTracking() }
        }
        RunLoop.main.add(t, forMode: .common)
        // The status item can be hidden behind the notch; pop the same menu at the top right.
        let f = NSScreen.main?.visibleFrame ?? .zero
        menu.popUp(positioning: nil, at: NSPoint(x: f.maxX - 300, y: f.maxY - 4), in: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Prefs.shared
        let account = Account.shared

        let header = NSMenuItem()
        let host = NSHostingView(rootView: MenuHeader(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 290, height: host.fittingSize.height)
        header.view = host
        menu.addItem(header)
        menu.addItem(.separator())

        let needsAccount = prefs.engine == .cloud && !account.isSignedIn
        let needsKey = prefs.engine == .openAI && prefs.effectiveAPIKey == nil
        if !controller.hotkeyActive || AudioRecorder.permission != .authorized || needsAccount || needsKey {
            menu.addItem(make("Finish Setup…", "exclamationmark.circle", #selector(openSetup)))
            menu.addItem(.separator())
        }

        menu.addItem(make("Open Oneshot", "macwindow", #selector(openMain)))
        menu.addItem(.separator())
        menu.addItem(make(controller.isRecording ? "Stop Dictation" : "Start Dictation", controller.isRecording ? "stop.circle" : "mic", #selector(toggle)))
        if !controller.isRecording { menu.addItem(make("Command Mode", "sparkles", #selector(command))) }
        if controller.canRetry { menu.addItem(make("Retry Last Dictation", "arrow.clockwise", #selector(retry))) }
        let pasteLast = make("Paste Last Transcript", "doc.on.clipboard", #selector(pasteLast))
        pasteLast.isEnabled = !HistoryStore.shared.items.isEmpty
        menu.addItem(pasteLast)

        let recent = make("Recent", "clock", nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        let items = HistoryStore.shared.items.prefix(8)
        if items.isEmpty {
            let none = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        for d in items {
            let flat = d.text.replacingOccurrences(of: "\n", with: " ")
            let title = flat.count > 52 ? String(flat.prefix(52)) + "…" : flat
            let mi = NSMenuItem(title: title, action: #selector(copyItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = d.text
            let meta = "\(d.app ?? "Unknown app") · \(rel.localizedString(for: d.date, relativeTo: Date()))"
            let attributed = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 13)])
            attributed.append(NSAttributedString(string: "\n" + meta, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            mi.attributedTitle = attributed
            sub.addItem(mi)
        }
        if !items.isEmpty {
            sub.addItem(.separator())
            let hint = NSMenuItem(title: "Click an item to copy it", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
        }
        recent.submenu = sub
        menu.addItem(recent)

        menu.addItem(.separator())
        if let v = Updater.shared.available {
            menu.addItem(make("Update to \(v)", "arrow.down.circle", #selector(update)))
        }
        let replies = FeedbackStore.shared.unreadReplies
        menu.addItem(make(replies > 0 ? "Feedback (\(replies) new \(replies == 1 ? "reply" : "replies"))" : "Send Feedback…", "bubble.left", #selector(feedback)))
        menu.addItem(make("Settings…", "gearshape", #selector(openSettings), key: ","))
        menu.addItem(make("Quit Oneshot", "power", #selector(quit), key: "q"))
    }

    private func make(_ title: String, _ symbol: String, _ sel: Selector?, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return mi
    }

    @objc private func toggle() { controller.toggle() }
    @objc private func command() { controller.startCommand() }
    @objc private func retry() { controller.retryLast() }
    @objc private func pasteLast() { controller.pasteLast() }
    @objc private func update() { Updater.shared.install() }
    @objc private func feedback() { AppDelegate.shared?.showMain(.feedback) }
    @objc private func openMain() { AppDelegate.shared?.showMain(.home) }
    @objc private func openSettings() { controller.openSettings?("general") }
    @objc private func openSetup() { AppDelegate.shared?.showOnboarding(step: nil) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func copyItem(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String { Paster.copy(s) }
    }
}

private struct MenuHeader: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var account = Account.shared
    @ObservedObject private var prefs = Prefs.shared

    private var status: String {
        if controller.isRecording { return "Listening…" }
        if controller.inFlight > 0 { return "Transcribing…" }
        if !controller.hotkeyActive { return "Finish setup to start" }
        return "Hold \(prefs.trigger.short) to dictate"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Oneshot").font(.system(size: 13, weight: .semibold))
                    Text(status).font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Spacer()
                if prefs.engine == .cloud, let email = account.email {
                    Text(email).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 120, alignment: .trailing)
                }
            }
            if prefs.engine == .cloud, let u = account.usage { UsageBar(usage: u) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(width: 290, alignment: .leading)
    }
}
