import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

// MARK: - Window

@MainActor
final class MainNav: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case home, history, dictionary, style, feedback
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "Home"
            case .history: return "History"
            case .dictionary: return "Dictionary"
            case .style: return "Style"
            case .feedback: return "Feedback"
            }
        }
        var symbol: String {
            switch self {
            case .home: return "house"
            case .history: return "clock.arrow.circlepath"
            case .dictionary: return "character.book.closed"
            case .style: return "wand.and.stars"
            case .feedback: return "bubble.left.and.text.bubble.right"
            }
        }
    }
    @Published var page: Page? = .home
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let nav = MainNav()
    private var window: NSWindow?

    func show(_ page: MainNav.Page? = nil, activate: Bool = true) {
        if let page { nav.page = page }
        if window == nil {
            let host = NSHostingController(rootView: MainView(nav: nav))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Oneshot"
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 940, height: 660))
            w.minSize = NSSize(width: 820, height: 560)
            w.setFrameAutosaveName("OneshotMain")
            if !w.setFrameUsingName("OneshotMain") { w.center() }
            w.delegate = self
            window = w
        }
        guard activate else { window?.orderFrontRegardless(); return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        if NSApp.windows.filter({ $0.isVisible && $0 !== window && $0.level == .normal }).isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct MainView: View {
    @ObservedObject var nav: MainNav

    var body: some View {
        NavigationSplitView {
            Sidebar(nav: nav)
                .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } detail: {
            Group {
                switch nav.page ?? .home {
                case .home: HomePage(nav: nav)
                case .history: PageScaffold(title: "History", subtitle: "Everything you've dictated, searchable.") { HistoryPane(embedded: true) }
                case .dictionary: DictionaryPage()
                case .style: StylePage()
                case .feedback: FeedbackPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 560)
    }
}

private struct Sidebar: View {
    @ObservedObject var nav: MainNav
    @ObservedObject private var feedback = FeedbackStore.shared
    var body: some View {
        List(selection: $nav.page) {
            ForEach(MainNav.Page.allCases) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
                    .font(.system(size: 13))
                    .padding(.vertical, 2)
                    .badge(p == .feedback ? feedback.unreadReplies : 0)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("Oneshot").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 34).padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }
}

private struct SidebarFooter: View {
    @ObservedObject private var account = Account.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if prefs.engine == .cloud, let u = account.usage, account.isSignedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Free plan").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    UsageBar(usage: u)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            Button { AppDelegate.shared?.showSettings(tab: "general") } label: {
                HStack(spacing: 9) {
                    Text(initial)
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Brand.gradient))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text("Settings").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "gearshape").foregroundColor(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .onHover { hover = $0 }
        }
        .padding(12)
    }

    private var title: String {
        if prefs.engine == .cloud { return account.email ?? "Not signed in" }
        return prefs.engine == .openAI ? "Your OpenAI key" : "On this Mac"
    }
    private var initial: String { String((account.email ?? NSFullUserName()).prefix(1)).uppercased() }
}

/// Title + subtitle header shared by pages.
struct PageScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold)).tracking(Brand.tracking(26))
                Text(subtitle).font(.system(size: 13)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 6)
            content()
        }
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var nav: MainNav
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var account = Account.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var pending = PendingStore.shared

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Good evening" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(greeting).font(.system(size: 28, weight: .bold)).tracking(Brand.tracking(28)).staggerIn(0)
                    HStack(spacing: 6) {
                        Text("Hold")
                        KeyCap(label: prefs.trigger.cap, pressed: controller.triggerHeld || controller.isRecording)
                        Text("in any app and start talking.")
                    }
                    .font(.system(size: 14)).foregroundColor(.secondary)
                    .staggerIn(1)
                    UsingChatGPTPlanLine().staggerIn(1)
                }

                if let v = updater.available {
                    UpdateBanner(version: v).staggerIn(2)
                }
                if prefs.engine == .cloud && !account.isSignedIn {
                    SignInBanner().staggerIn(2)
                }
                if !pending.items.isEmpty {
                    PendingBanner(count: pending.items.count) { nav.page = .history }.staggerIn(2)
                }
                if account.isSignedIn || prefs.engine != .cloud {
                    ChatGPTInviteBanner().staggerIn(2)
                }

                if history.items.isEmpty {
                    FirstDictationCard().staggerIn(2)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        WeekCard().frame(maxWidth: .infinity)
                        VStack(spacing: 14) {
                            MetricCard(symbol: "clock.badge.checkmark", value: timeSaved, label: "saved vs. typing")
                            MetricCard(symbol: "speedometer", value: history.wordsPerMinute.map { "\($0) wpm" } ?? "—", label: "speaking speed")
                            MetricCard(symbol: "flame", value: "\(history.streak) day\(history.streak == 1 ? "" : "s")", label: "streak")
                        }
                        .frame(width: 210)
                    }
                    .staggerIn(2)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Recent").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Button("See all") { nav.page = .history }.buttonStyle(.link).font(.system(size: 12))
                        }
                        VStack(spacing: 0) {
                            let recent = Array(history.items.prefix(5))
                            ForEach(recent) { d in
                                RecentRow(d: d)
                                if d.id != recent.last?.id { Divider().padding(.leading, 56) }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .surface(radius: 14)
                    }
                    .staggerIn(3)
                }

                TipCard().staggerIn(4)
            }
            .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 32)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var timeSaved: String {
        let m = history.minutesSaved
        return m < 1 ? "<1 min" : m < 60 ? "\(Int(m)) min" : String(format: "%.1f h", m / 60)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: 14)
    }
}

private struct WeekCard: View {
    @ObservedObject private var history = HistoryStore.shared
    var body: some View {
        let days = history.dailyWords(days: 7)
        // Quiet days get a short stub so the week reads as seven days, not one lonely bar.
        let stub = max(1, Double(days.map(\.words).max() ?? 0) * 0.035)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This week").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(days.reduce(0) { $0 + $1.words }.formatted())
                            .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                            .tracking(Brand.tracking(30))
                        Text("words").font(.system(size: 13)).foregroundColor(.secondary)
                    }
                }
                Chart(days, id: \.day) { d in
                    let today = Calendar.current.isDateInToday(d.day)
                    BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words > 0 ? Double(d.words) : stub), width: .ratio(0.55))
                        .foregroundStyle(d.words == 0 ? AnyShapeStyle(Color.primary.opacity(0.08))
                                         : today ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Brand.accent.opacity(0.35)))
                        .cornerRadius(5)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 150)
            }
        }
    }
}

private struct MetricCard: View {
    let symbol: String
    let value: String
    let label: String
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.accent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()).tracking(Brand.tracking(17) / 2)
                    Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
    }
}

private struct RecentRow: View {
    let d: Dictation
    @State private var hover = false
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(bundleID: d.bundleID, name: d.app).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.text).font(.system(size: 13)).lineLimit(2)
                HStack(spacing: 4) {
                    if d.mode == "command" { Image(systemName: "sparkles").foregroundColor(Brand.accent) }
                    Text(d.app ?? "Unknown app")
                    Text("·")
                    Text(d.date, style: .relative)
                    Text("ago")
                }
                .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                Paster.copy(d.text)
                withAnimation(Brand.quick) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(Brand.quick) { copied = false } }
            } label: {
                ZStack {
                    if copied { Image(systemName: "checkmark").foregroundColor(Brand.success).transition(.iconSwap) }
                    else { Image(systemName: "doc.on.doc").transition(.iconSwap) }
                }
                .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle().inset(by: -6))
            }
            .buttonStyle(PressableStyle())
            .opacity(hover || copied ? 1 : 0)
            .help("Copy")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.primary.opacity(hover ? 0.03 : 0))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct AppIconView: View {
    let bundleID: String?
    let name: String?
    /// The system's generic app icon: an app we can't find still looks like an app, not a missing image.
    private static let generic: NSImage = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
        ?? NSWorkspace.shared.icon(for: .application)
    var body: some View {
        Image(nsImage: AppIcons.icon(bundleID: bundleID, name: name) ?? Self.generic).resizable().interpolation(.high)
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(bundleID: String?, name: String?) -> NSImage? {
        let key = bundleID ?? name ?? ""
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }
        var url: URL?
        if let b = bundleID { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) }
        if url == nil, let name {
            for dir in ["/Applications", "/System/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name + ".app")
                if FileManager.default.fileExists(atPath: candidate.path) { url = candidate; break }
            }
        }
        guard let url else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[key] = img
        return img
    }
}

private struct FirstDictationCard: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var controller = AppController.shared
    @State private var text = ""
    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 22) {
                KeyCap(label: prefs.trigger.cap, pressed: controller.triggerHeld || controller.isRecording, large: true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Try your first dictation").font(.system(size: 16, weight: .semibold))
                    Text("Click the box, hold \(prefs.trigger.short), and say anything. Oneshot removes the “ums”, fixes corrections and punctuates for you.")
                        .font(.system(size: 12.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("Your words appear here…", text: $text, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(6)
        }
    }
}

private struct UpdateBanner: View {
    let version: String
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text("Oneshot \(version) is ready").font(.system(size: 13.5, weight: .semibold))
                Text("Takes a few seconds. Oneshot restarts by itself.").font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Button(updater.installing ? "Updating…" : "Update now") { updater.install() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(updater.installing)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent.opacity(0.35), lineWidth: 1.2))
    }
}

private struct SignInBanner: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text("Create your free account to start dictating").font(.system(size: 13.5, weight: .semibold))
                Text("30 free minutes a week, no API key needed. Takes ten seconds.").font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Button("Get started") { AppDelegate.shared?.showOnboarding(step: .account) }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent.opacity(0.35), lineWidth: 1.2))
        .shadow(color: Brand.accent.opacity(0.12), radius: 10, y: 3)
    }
}

private struct TipCard: View {
    @ObservedObject private var prefs = Prefs.shared
    private var tips: [(String, String, String)] {
        let k = prefs.trigger.short
        return [
            ("sparkles", "Rewrite anything", "Select text, hold \(k) and ⌃, then say “make this friendlier” or “translate to English”."),
            ("hands.and.sparkles", "Go hands-free", "Double-tap \(k) to dictate without holding the key. Tap it again when you're done."),
            ("character.book.closed", "Teach it your words", "Add names and jargon to your Dictionary so Oneshot spells them right."),
            ("arrow.uturn.backward", "Change your mind mid-sentence", "Say “at 2, actually 3” and Oneshot keeps only what you meant."),
            ("list.bullet", "Speak in lists", "Say “first… second… third…” and Oneshot formats a list in docs and AI prompts."),
        ]
    }
    var body: some View {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let tip = tips[day % tips.count]
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tip.0)
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.gradient))
            VStack(alignment: .leading, spacing: 3) {
                Text("Tip · \(tip.1)").font(.system(size: 13, weight: .semibold))
                Text(tip.2).font(.system(size: 12.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.accent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent.opacity(0.15)))
    }
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var newTerm = ""
    @FocusState private var focused: Bool

    var body: some View {
        PageScaffold(title: "Dictionary", subtitle: "Names, products and jargon Oneshot should always spell your way.") {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").foregroundColor(Brand.accent).font(.system(size: 16))
                    TextField("Add a word, then press Return", text: $newTerm)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .focused($focused)
                        .onSubmit(add)
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(focused ? Brand.accent.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: focused ? 1.5 : 1))
                .animation(Brand.quick, value: focused)

                if prefs.vocabularyTerms.isEmpty {
                    VStack(spacing: 10) {
                        SymbolTile(symbol: "character.book.closed.fill", size: 56)
                        Text("Your dictionary is empty").font(.system(size: 15, weight: .semibold))
                        Text("Add your name, your company, product names or acronyms.\nOneshot listens for them and spells them exactly as written.")
                            .font(.system(size: 12.5)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 50)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(prefs.vocabularyTerms, id: \.self) { t in
                            TermChip(term: t) { remove(t) }.transition(.iconSwap)
                        }
                    }
                    .animation(Brand.spring, value: prefs.vocabularyTerms)
                }
                Spacer()
            }
            .padding(.horizontal, 32).padding(.top, 18)
        }
    }

    private func add() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !prefs.vocabularyTerms.contains(t) else { newTerm = ""; return }
        prefs.vocabulary = (prefs.vocabularyTerms + [t]).joined(separator: "\n")
        newTerm = ""
    }
    private func remove(_ t: String) {
        prefs.vocabulary = prefs.vocabularyTerms.filter { $0 != t }.joined(separator: "\n")
    }
}

// MARK: - Style

private struct StylePage: View {
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        PageScaffold(title: "Style", subtitle: "How Oneshot turns what you say into what you'd have typed.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            StyleToggle(isOn: $prefs.cleanupEnabled, title: "Clean up what you say",
                                        detail: "Removes “um” and “like”, applies corrections (“at 2, actually 3” → “at 3”), adds punctuation and lists.")
                            Divider()
                            StyleToggle(isOn: $prefs.useContext, title: "Use the text before your cursor",
                                        detail: "Continues sentences naturally. Sends up to 600 characters; password fields are never read.")
                        }
                    }
                    Text("Adapts to where you type").font(.system(size: 15, weight: .semibold)).padding(.top, 4)
                    Card {
                        VStack(spacing: 12) {
                            StyleRow(symbol: "bubble.left.and.bubble.right.fill", title: "Messages", detail: "Slack, WhatsApp, Messages", sample: "sounds good, see you at 3")
                            Divider()
                            StyleRow(symbol: "envelope.fill", title: "Email", detail: "Mail, Gmail, Outlook", sample: "Complete sentences and paragraphs.")
                            Divider()
                            StyleRow(symbol: "chevron.left.forwardslash.chevron.right", title: "Code", detail: "Xcode, VS Code, Cursor, Terminal", sample: "git push --force-with-lease")
                            Divider()
                            StyleRow(symbol: "sparkles", title: "AI prompts", detail: "ChatGPT, Claude, Codex", sample: "Clear, structured requirements.")
                            Divider()
                            StyleRow(symbol: "doc.text.fill", title: "Docs & notes", detail: "Notion, Notes, Google Docs", sample: "Well-formed prose and lists.")
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 32)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
    }
}

private struct StyleToggle: View {
    @Binding var isOn: Bool
    let title: String
    let detail: String
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }
}

/// Shown on Home while saved recordings are waiting to be tried again.
private struct PendingBanner: View {
    let count: Int
    let open: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 recording didn't go through" : "\(count) recordings didn't go through").font(.system(size: 13.5, weight: .semibold))
                Text("The audio is saved. Try it again whenever you like.").font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            Button("Review", action: open).buttonStyle(SecondaryButtonStyle())
        }
        .padding(14)
        .surface(radius: 14)
    }
}
