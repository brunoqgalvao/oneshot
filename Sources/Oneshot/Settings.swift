import SwiftUI
import AppKit
import AVFoundation
import Speech
import ServiceManagement
import ApplicationServices

enum SystemPane {
    static func open(_ anchor: String) {
        let urls = [
            "mic": "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "ax": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "speech": "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            "keyboard": "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        ]
        if let s = urls[anchor], let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

final class PermissionsModel: ObservableObject {
    @Published var mic = AudioRecorder.permission
    @Published var ax = AXIsProcessTrusted()
    @Published var speech = AppleTranscriber.status
    private var timer: Timer?

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }
    func refresh() {
        if mic != AudioRecorder.permission { mic = AudioRecorder.permission }
        if ax != AXIsProcessTrusted() { ax = AXIsProcessTrusted() }
        if speech != AppleTranscriber.status { speech = AppleTranscriber.status }
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    enum Pane: String, CaseIterable {
        case general, account
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .account: return "person.crop.circle"
            }
        }
        static func from(_ s: String?) -> Pane? {
            switch s {
            case "ai", "account": return .account
            case "setup", "general": return .general
            default: return nil
            }
        }
    }

    private var window: NSWindow?
    private let tabs = TitledTabViewController()

    func show(_ pane: Pane?, activate: Bool = true) {
        if window == nil { build() }
        if let pane, let i = Pane.allCases.firstIndex(of: pane) { tabs.selectedTabViewItemIndex = i }
        window?.title = tabs.tabView.selectedTabViewItem?.label ?? "Oneshot"
        guard activate else { window?.orderFrontRegardless(); return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private func build() {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        for pane in Pane.allCases {
            let host: NSViewController
            switch pane {
            case .general: host = hosting(GeneralPane())
            case .account: host = hosting(AccountPane())
            }
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
    }

    private func hosting<V: View>(_ v: V) -> NSViewController {
        let h = NSHostingController(rootView: v)
        h.sizingOptions = [.preferredContentSize]
        return h
    }

    func windowWillClose(_ notification: Notification) {
        if NSApp.windows.filter({ $0.isVisible && $0 !== window && $0.level == .normal }).isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Keeps the window title in sync with the selected pane.
final class TitledTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Oneshot"
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = tabView.selectedTabViewItem?.label ?? "Oneshot"
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @StateObject private var perms = PermissionsModel()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var devices = AudioDevices.inputs()

    var body: some View {
        Form {
            Section {
                Picker("Hold to talk", selection: $prefs.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                }
                ShortcutList(trigger: prefs.trigger.cap).padding(.vertical, 6)
            } header: { Text("Dictation key") }

            Section {
                Picker("Microphone", selection: $prefs.inputDeviceUID) {
                    Text("System default" + (AudioDevices.defaultInputName().map { " (\($0))" } ?? "")).tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                Picker("Language", selection: $prefs.language) {
                    Text("Detect automatically").tag("auto")
                    Divider()
                    Text("English").tag("en")
                    Text("Português").tag("pt")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Italiano").tag("it")
                }
            } header: { Text("Input") }

            Section {
                Toggle("Show the Oneshot dot at the bottom of the screen", isOn: $prefs.showIndicator)
                Toggle("Play sounds", isOn: $prefs.sounds)
                Toggle(isOn: $prefs.keepOnClipboard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep the latest dictation on the clipboard")
                        Text("Paste it again anywhere with ⌘V. Turn off to restore what you had copied before.")
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            } header: { Text("Behavior") }

            Section {
                PermissionRow(title: "Microphone", ok: perms.mic == .authorized,
                              action: perms.mic == .notDetermined ? "Allow" : "Open Settings") {
                    if perms.mic == .notDetermined { AudioRecorder.requestPermission { _ in perms.refresh() } } else { SystemPane.open("mic") }
                }
                PermissionRow(title: "Accessibility", ok: perms.ax, action: "Open Settings") { SystemPane.open("ax") }
                PermissionRow(title: "Speech Recognition", subtitle: "Optional, for offline transcription", ok: perms.speech == .authorized,
                              action: perms.speech == .notDetermined ? "Allow" : "Open Settings") {
                    if perms.speech == .notDetermined { AppleTranscriber.requestPermission { _ in perms.refresh() } } else { SystemPane.open("speech") }
                }
                Button("Run setup again…") { AppDelegate.shared?.showOnboarding(step: .welcome) }
                    .buttonStyle(.link)
            } header: { Text("Permissions") }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 800)
        .onAppear { perms.startPolling(); devices = AudioDevices.inputs() }
        .onDisappear { perms.stopPolling() }
    }
}

private struct PermissionRow: View {
    let title: String
    var subtitle: String? = nil
    let ok: Bool
    let action: String
    let perform: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            StatusDot(ok: ok, optional: subtitle != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary) }
            }
            Spacer()
            if ok {
                Text("Allowed").font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                Button(action, action: perform).controlSize(.small)
            }
        }
    }
}

// MARK: - Account

struct AccountPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var account = Account.shared
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    ForEach(Engine.allCases) { e in
                        EngineCard(engine: e, selected: prefs.engine == e) { withAnimation(Brand.spring) { prefs.engine = e } }
                    }
                }
                .padding(.vertical, 4)
            } header: { Text("How Oneshot transcribes") }

            Section {
                switch prefs.engine {
                case .cloud:
                    if account.isSignedIn { AccountCard().padding(.vertical, 4) }
                    else { AccountForm().padding(.vertical, 6) }
                case .openAI:
                    SecureField("API key", text: $prefs.apiKey)
                    HStack {
                        Button(testing ? "Testing…" : "Test connection") { test() }
                            .disabled(testing || prefs.effectiveAPIKey == nil)
                        if let testResult { Text(testResult).font(.system(size: 12)).foregroundColor(.secondary) }
                    }
                    Picker("Speech model", selection: $prefs.transcribeModel) {
                        Text("gpt-4o-transcribe").tag("gpt-4o-transcribe")
                        Text("gpt-4o-mini-transcribe").tag("gpt-4o-mini-transcribe")
                        Text("gpt-transcribe").tag("gpt-transcribe")
                        Text("whisper-1").tag("whisper-1")
                    }
                    Picker("Cleanup model", selection: $prefs.cleanupModel) {
                        Text("gpt-5.4-mini").tag("gpt-5.4-mini")
                        Text("gpt-5.4-nano").tag("gpt-5.4-nano")
                        Text("gpt-4.1-mini").tag("gpt-4.1-mini")
                    }
                case .apple:
                    Text("Audio never leaves this Mac. Cleanup and Command mode need a Oneshot account or an OpenAI key.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    if AppleTranscriber.status != .authorized {
                        Button("Allow Speech Recognition") { AppleTranscriber.requestPermission { _ in } }
                    }
                }
            } header: { Text(prefs.engine == .cloud ? "Account" : prefs.engine == .openAI ? "OpenAI" : "On-device") }

            if prefs.engine != .apple {
                Section {
                    Toggle(isOn: $prefs.offlineFallback) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transcribe on this Mac when offline")
                            Text("Uses Apple's on-device speech recognition if the server can't be reached.")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 600)
        .animation(Brand.spring, value: prefs.engine)
        .animation(Brand.spring, value: account.isSignedIn)
    }

    private func test() {
        guard let key = prefs.effectiveAPIKey else { return }
        testing = true
        testResult = nil
        let start = Date()
        Task { @MainActor in
            do {
                _ = try await OpenAIClient(apiKey: key).chat(model: prefs.cleanupModel, system: "Reply with OK.", user: "ping", maxTokens: 20)
                testResult = "Connected in \(String(format: "%.1f", Date().timeIntervalSince(start)))s"
            } catch {
                testResult = AppController.describe(error)
            }
            testing = false
        }
    }
}

private struct EngineCard: View {
    let engine: Engine
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    private var info: (String, String, String) {
        switch engine {
        case .cloud: return ("sparkles", "Oneshot account", "Free. Best accuracy and cleanup, nothing to set up.")
        case .openAI: return ("key.fill", "Your own OpenAI key", "Calls OpenAI directly; billed to your account.")
        case .apple: return ("lock.fill", "On this Mac", "Private and offline. Less accurate, no cleanup.")
        }
    }

    var body: some View {
        let (symbol, title, detail) = info
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.45))))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.primary)
                    Text(detail).font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Spacer()
                ZStack {
                    Circle().strokeBorder(selected ? Brand.accent : Color.secondary.opacity(0.4), lineWidth: selected ? 5 : 1.5)
                }
                .frame(width: 18, height: 18)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Brand.accent.opacity(0.09) : Color.primary.opacity(hover ? 0.04 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { hover = $0 }
    }
}

struct TermChip: View {
    let term: String
    let onRemove: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 4) {
            Text(term).font(.system(size: 12, weight: .medium))
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                    .background(Circle().fill(Color.primary.opacity(hover ? 0.15 : 0.08)))
                    .contentShape(Circle().inset(by: -6))
            }
            .buttonStyle(PressableStyle())
            .onHover { hover = $0 }
        }
        .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 4)
        .background(Capsule().fill(Brand.accent.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Brand.accent.opacity(0.2)))
    }
}

struct StyleRow: View {
    let symbol: String
    let title: String
    let detail: String
    let sample: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(Brand.accent)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Text(sample).font(.system(size: 11, design: title == "Code" ? .monospaced : .default)).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: subviews.isEmpty ? 0 : y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - History

struct HistoryPane: View {
    var embedded = false
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var pending = PendingStore.shared
    @State private var query = ""

    private var filtered: [Dictation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? history.items : history.items.filter { $0.text.lowercased().contains(q) || ($0.app ?? "").lowercased().contains(q) }
    }

    private var groups: [(String, [Dictation])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) { label = "Today" }
            else if cal.isDateInYesterday(day) { label = "Yesterday" }
            else { label = day.formatted(.dateTime.weekday(.wide).month().day()) }
            return (label, byDay[day]!.sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                HStack(spacing: 12) {
                    StatCard(value: history.totalWords.formatted(), label: "words")
                    StatCard(value: history.items.count.formatted(), label: "dictations")
                    StatCard(value: String(format: "%.0f min", history.minutesSaved), label: "saved vs. typing")
                }
                .padding(.horizontal, 20).padding(.top, 18)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search dictations", text: $query).textFieldStyle(.plain)
                if !history.items.isEmpty {
                    Menu {
                        Button("Clear history", role: .destructive) { history.clear() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, embedded ? 32 : 20).padding(.vertical, 14)

            if !pending.items.isEmpty {
                PendingList()
                    .padding(.horizontal, embedded ? 32 : 20).padding(.bottom, 14)
            }

            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    SymbolTile(symbol: history.items.isEmpty ? "waveform" : "magnifyingglass", size: 56)
                    Text(history.items.isEmpty ? "No dictations yet" : "No matches").font(.system(size: 15, weight: .semibold))
                    Text(history.items.isEmpty ? "Hold \(Prefs.shared.trigger.short) in any app and start talking." : "Try a different word.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.0) { label, items in
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(items) { d in
                                        HistoryRow(d: d)
                                        if d.id != items.last?.id { Divider().padding(.leading, 14) }
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                            } header: {
                                Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 4).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.regularMaterial.opacity(0.0))
                            }
                        }
                    }
                    .padding(.horizontal, embedded ? 32 : 20).padding(.bottom, 20)
                }
            }
        }
        .frame(width: embedded ? nil : 620, height: embedded ? nil : 620)
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct HistoryRow: View {
    let d: Dictation
    @State private var hover = false
    @State private var copied = false
    @State private var showRaw = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(showRaw ? d.raw : d.text)
                    .font(.system(size: 13))
                    .foregroundColor(showRaw ? .secondary : .primary)
                    .lineLimit(showRaw ? nil : 8)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    if d.mode == "command" { Image(systemName: "sparkles").foregroundColor(Brand.accent) }
                    Text(d.app ?? "Unknown app")
                    Text("·")
                    Text(d.date.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text("\(String(format: "%.1f", d.latency))s").monospacedDigit()
                    if d.raw != d.text {
                        Button(showRaw ? "Show result" : "Show original") { withAnimation(Brand.quick) { showRaw.toggle() } }
                            .buttonStyle(.link)
                            .opacity(hover ? 1 : 0)
                    }
                }
                .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                Paster.copy(d.text)
                withAnimation(Brand.quick) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(Brand.quick) { copied = false } }
            } label: {
                ZStack {
                    if copied { Image(systemName: "checkmark").foregroundColor(Brand.success).transition(.iconSwap) }
                    else { Image(systemName: "doc.on.doc").transition(.iconSwap) }
                }
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.07 : 0)))
                .contentShape(Circle().inset(by: -6))
            }
            .buttonStyle(PressableStyle())
            .foregroundColor(.secondary)
            .opacity(hover || copied ? 1 : 0)
            .help("Copy")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Recordings that didn't go through

/// Saved recordings that failed to transcribe, each with Try again and Delete.
struct PendingList: View {
    @ObservedObject private var pending = PendingStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("Couldn't transcribe").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).textCase(.uppercase)
                Spacer()
                Text("The audio is saved on this Mac").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(pending.items) { p in
                    PendingRow(p: p)
                    if p.id != pending.items.last?.id { Divider().padding(.leading, 56) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .surface(radius: 12)
        }
    }
}

private struct PendingRow: View {
    let p: PendingDictation
    @ObservedObject private var controller = AppController.shared
    private var busy: Bool { controller.retrying.contains(p.id) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: p.command ? "sparkles" : "waveform")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.orange)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Self.length(p.duration)) recording\(p.command ? " (command)" : "")").font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    Text(p.app ?? "Unknown app")
                    Text("·")
                    Text(p.date.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(p.error).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                controller.retry(p.id)
            } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "Trying…" : "Try again")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(busy)
            .help("Transcribe it again. The text is copied to your clipboard and added to History.")
            Button { PendingStore.shared.remove(p.id) } label: {
                Image(systemName: "trash").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .disabled(busy)
            .help("Delete this recording")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    static func length(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return "\(t / 60) min \(t % 60) s" }
        return "\(t / 3600) h \((t % 3600) / 60) min"
    }
}
