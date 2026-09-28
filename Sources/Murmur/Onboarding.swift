import SwiftUI
import AppKit
import ServiceManagement
import ApplicationServices

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, account, microphone, accessibility, globe, practice, done }

    @Published var step: Step = .welcome
    @Published var forward = true
    var onFinish: (() -> Void)?

    static var fnUsage: Int? {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        return CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
    }

    func isSatisfied(_ s: Step) -> Bool {
        let prefs = Prefs.shared
        switch s {
        case .account:
            switch prefs.engine {
            case .cloud: return Account.shared.isSignedIn
            case .openAI: return prefs.effectiveAPIKey != nil
            case .apple: return true
            }
        case .microphone: return AudioRecorder.permission == .authorized
        case .accessibility: return AXIsProcessTrusted() && AppController.shared.hotkeyActive
        default: return false
        }
    }

    func next() {
        var n = step.rawValue + 1
        while let s = Step(rawValue: n), isSatisfied(s) { n += 1 }
        go(to: Step(rawValue: n) ?? .done, forward: true)
    }

    func back() {
        var n = step.rawValue - 1
        while n > 0, let s = Step(rawValue: n), isSatisfied(s) { n -= 1 }
        go(to: Step(rawValue: max(0, n)) ?? .welcome, forward: false)
    }

    func go(to s: Step, forward: Bool = true) {
        self.forward = forward
        withAnimation(.spring(response: 0.5, dampingFraction: 1)) { step = s }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model = OnboardingModel()
    private var window: NSWindow?

    func show(step: OnboardingModel.Step? = nil, activate: Bool = true) {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView(model: model))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.title = "Welcome to Murmur"
            w.setContentSize(NSSize(width: 580, height: 660))
            w.center()
            w.delegate = self
            window = w
        }
        if let step { model.step = step }
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

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack {
            VisualEffect(material: .underWindowBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    stepView
                        .id(model.step)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: Brand.reduceMotion ? 0 : (model.forward ? 36 : -36))),
                            removal: .opacity.combined(with: .offset(x: Brand.reduceMotion ? 0 : (model.forward ? -16 : 16)))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        .frame(width: 580, height: 660)
    }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .account: AccountStep(model: model)
        case .microphone: MicrophoneStep(model: model)
        case .accessibility: AccessibilityStep(model: model)
        case .globe: KeyStep(model: model)
        case .practice: PracticeStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { model.back() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .opacity(model.step == .welcome || model.step == .done ? 0 : 1)
                .frame(width: 80, alignment: .leading)
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == model.step ? Brand.violet : Color.primary.opacity(0.15))
                        .frame(width: s == model.step ? 18 : 6, height: 6)
                }
            }
            .animation(Brand.spring, value: model.step)
            Spacer()
            Color.clear.frame(width: 80, height: 1)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
        .padding(.top, 8)
    }
}

/// Shared layout: art, title, subtitle, content, actions — each staggered in.
private struct StepScaffold<Art: View, Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let art: () -> Art
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 44)
            art().staggerIn(0)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 26)
                .staggerIn(1)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 410)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .staggerIn(2)
            content()
                .padding(.top, 26)
                .staggerIn(3)
            Spacer(minLength: 16)
            actions().staggerIn(4)
        }
        .padding(.horizontal, 56)
    }
}

// MARK: Steps

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel
    var body: some View {
        StepScaffold(title: "Talk instead of type",
                     subtitle: "Hold fn in any app, speak naturally, and Murmur types clean, punctuated text right where your cursor is.") {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                .shadow(color: Brand.violet.opacity(0.3), radius: 16, y: 6)
        } content: {
            DemoStage()
        } actions: {
            Button("Get started") { model.next() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A looping, self-running preview of the HUD: listening → thinking → done.
private struct DemoStage: View {
    @StateObject private var hud = HUDModel()
    @State private var timer: Timer?
    @State private var typed = ""
    private let sentence = "Let's meet at 3pm and bring the Q3 numbers."

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                Text(typed).font(.system(size: 13)).foregroundColor(.white.opacity(0.9))
                Rectangle().fill(Brand.violet).frame(width: 1.5, height: 15).opacity(0.9)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            ZStack {
                if !hud.phase.isHidden {
                    Pill(model: hud).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
            }
            .frame(height: 44)
        }
        .padding(18)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .environment(\.colorScheme, .dark)
        .onAppear(perform: start)
        .onDisappear { timer?.invalidate() }
    }

    private func start() {
        var t = 0.0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                t += 1.0 / 30
                let cycle = t.truncatingRemainder(dividingBy: 6.4)
                switch cycle {
                case 0..<0.05:
                    typed = ""
                    withAnimation(Brand.spring) { hud.phase = .listening }
                case 0.05..<2.8:
                    let syllable = abs(sin(cycle * 11)) * (0.55 + 0.45 * sin(cycle * 2.3))
                    hud.push(level: CGFloat(0.15 + 0.85 * syllable))
                case 2.8..<3.9:
                    if hud.phase != .processing { withAnimation(Brand.spring) { hud.phase = .processing } }
                case 3.9..<5.6:
                    if hud.phase == .processing {
                        typed = sentence
                        withAnimation(Brand.spring) { hud.phase = .done("9 words · 0.9s") }
                    }
                default:
                    if !hud.phase.isHidden { withAnimation(.easeIn(duration: 0.16)) { hud.phase = .hidden } }
                }
            }
        }
    }
}

private struct AccountStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        StepScaffold(title: prefs.engine == .openAI ? "Add your OpenAI key" : "Create your free account",
                     subtitle: prefs.engine == .openAI
                        ? "Murmur calls OpenAI directly with your key. Usage is billed to your OpenAI account."
                        : "Murmur's server does the transcription, so there's no API key to set up. 30 free minutes every day.") {
            SymbolTile(symbol: prefs.engine == .openAI ? "key.fill" : "person.crop.circle.fill")
        } content: {
            Group {
                if prefs.engine == .openAI {
                    VStack(spacing: 10) {
                        SecureField("sk-…", text: $prefs.apiKey).textFieldStyle(.roundedBorder).controlSize(.large)
                        Button("Continue") { model.next() }
                            .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                            .disabled(prefs.effectiveAPIKey == nil)
                    }
                } else {
                    AccountForm(onSuccess: { model.next() })
                }
            }
            .frame(width: 340)
        } actions: {
            Button(prefs.engine == .openAI ? "Use a free Murmur account instead" : "I have my own OpenAI key") {
                withAnimation(Brand.spring) { prefs.engine = prefs.engine == .openAI ? .cloud : .openAI }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }
}

private struct MicrophoneStep: View {
    @ObservedObject var model: OnboardingModel
    @State private var status = AudioRecorder.permission
    private let poll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        StepScaffold(title: "Allow the microphone",
                     subtitle: "Murmur only listens while you hold the dictation key. The orange dot in the menu bar tells you when it's on.") {
            SymbolTile(symbol: "mic.fill")
        } content: {
            PermissionState(granted: status == .authorized, grantedText: "Microphone allowed")
        } actions: {
            if status == .authorized {
                Button("Continue") { model.next() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else if status == .notDetermined {
                Button("Allow Microphone") { AudioRecorder.requestPermission { _ in status = AudioRecorder.permission } }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else {
                Button("Open System Settings") { SystemPane.open("mic") }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .onReceive(poll) { _ in
            let s = AudioRecorder.permission
            if s != status {
                status = s
                if s == .authorized { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { model.next() } }
            }
        }
    }
}

private struct AccessibilityStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var controller = AppController.shared
    @State private var trusted = AXIsProcessTrusted()
    @State private var waited = 0
    private let poll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var ready: Bool { trusted && controller.hotkeyActive }

    var body: some View {
        StepScaffold(title: "Let Murmur type for you",
                     subtitle: "Accessibility access lets Murmur notice when you hold the key and paste text into the app you're using. It never records your screen.") {
            SymbolTile(symbol: "keyboard.fill")
        } content: {
            if ready {
                PermissionState(granted: true, grantedText: "Accessibility allowed")
            } else {
                SettingsToggleMock()
            }
        } actions: {
            if ready {
                Button("Continue") { model.next() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            } else if trusted && waited > 6 {
                VStack(spacing: 8) {
                    Button("Restart Murmur") { Relaunch.now() }.buttonStyle(PrimaryButtonStyle())
                    Text("macOS sometimes needs a restart to apply the permission.").font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else {
                Button("Open System Settings") {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(opts)
                    SystemPane.open("ax")
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .onReceive(poll) { _ in
            let wasReady = ready
            trusted = AXIsProcessTrusted()
            if trusted && !controller.hotkeyActive { waited += 1 }
            if !wasReady && ready { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { model.next() } }
        }
    }
}

/// A small replica of the System Settings row the user needs to switch on.
private struct SettingsToggleMock: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
            Text("Murmur").font(.system(size: 13, weight: .medium))
            Spacer()
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.18)).frame(width: 38, height: 22)
                Circle().fill(.white).frame(width: 18, height: 18).shadow(color: .black.opacity(0.2), radius: 1, y: 1).padding(2)
            }
        }
        .padding(.horizontal, 14).frame(width: 320, height: 48)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .overlay(alignment: .bottom) {
            Text("Privacy & Security → Accessibility").font(.system(size: 11)).foregroundColor(.secondary).offset(y: 22)
        }
        .onAppear {
            guard !Brand.reduceMotion else { on = true; return }
            withAnimation(.spring(response: 0.4, dampingFraction: 1).delay(0.9).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

private struct PermissionState: View {
    let granted: Bool
    let grantedText: String
    var body: some View {
        ZStack {
            if granted {
                HStack(spacing: 8) {
                    DrawnCheck(size: 22)
                    Text(grantedText).font(.system(size: 14, weight: .medium))
                }
                .transition(.iconSwap)
            } else {
                Color.clear.frame(height: 22)
            }
        }
        .animation(Brand.spring, value: granted)
    }
}

private struct KeyStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var prefs = Prefs.shared
    @State private var fnUsage = OnboardingModel.fnUsage
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        StepScaffold(title: "Pick your dictation key",
                     subtitle: "Hold it in any app to talk. Double-tap it for hands-free.") {
            KeyCap(label: prefs.trigger == .fn ? "fn" : "⌥", large: true)
        } content: {
            HStack(spacing: 12) {
                KeyOption(selected: prefs.trigger == .fn, key: "fn", title: "Globe key", detail: fnDetail, warn: fnUsage != 0) {
                    withAnimation(Brand.spring) { prefs.trigger = .fn }
                }
                KeyOption(selected: prefs.trigger == .rightOption, key: "⌥", title: "Right Option", detail: "Works on any keyboard, including external ones.", warn: false) {
                    withAnimation(Brand.spring) { prefs.trigger = .rightOption }
                }
            }
        } actions: {
            VStack(spacing: 10) {
                if prefs.trigger == .fn && fnUsage != 0 {
                    Button("Open Keyboard Settings") { SystemPane.open("keyboard") }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Continue") { model.next() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .onReceive(poll) { _ in fnUsage = OnboardingModel.fnUsage }
    }

    private var fnDetail: String {
        fnUsage == 0 ? "Ready to go." : "Set “Press 🌐 key to” to Do Nothing so it doesn't open the emoji picker."
    }
}

private struct KeyOption: View {
    let selected: Bool
    let key: String
    let title: String
    let detail: String
    let warn: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    KeyCap(label: key, pressed: selected)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundColor(selected ? Brand.violet : .secondary.opacity(0.5))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
                HStack(alignment: .top, spacing: 5) {
                    if selected && warn { Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange).font(.system(size: 11)) }
                    Text(detail).font(.system(size: 11.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 196, height: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Brand.violet.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(hover ? 1 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Brand.violet.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(Brand.quick) { hover = h } }
    }
}

private struct PracticeStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var text = ""
    @State private var startCount = HistoryStore.shared.items.count
    @FocusState private var focused: Bool

    private var result: Dictation? { history.items.count > startCount ? history.items.first : nil }

    var body: some View {
        StepScaffold(title: result == nil ? "Give it a try" : "That's Murmur",
                     subtitle: result == nil
                        ? "Hold \(prefs.trigger.short) and say: “Um, let's meet at two, actually three, new line, thanks!”"
                        : "Fillers gone, corrections applied, formatting done. It works like this in every app.") {
            KeyCap(label: prefs.trigger == .fn ? "fn" : "⌥", pressed: controller.triggerHeld || controller.isRecording, large: true)
        } content: {
            VStack(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(8)
                    if text.isEmpty {
                        Text("Your words appear here…").font(.system(size: 14)).foregroundColor(.secondary.opacity(0.7))
                            .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                    }
                }
                .frame(width: 440, height: 96)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(focused ? Brand.violet.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 1))
                .animation(Brand.quick, value: focused)

            }
            .onChange(of: result?.id) { _ in
                // Safety net: if the paste didn't land in the box, show the result anyway.
                guard let r = result else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !text.contains(r.text.trimmingCharacters(in: .whitespaces)) {
                        text = text.isEmpty ? r.text.trimmingCharacters(in: .whitespaces) : text + " " + r.text.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } actions: {
            Button(result == nil ? "Skip for now" : "Continue") { model.next() }
                .buttonStyle(result == nil ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
        }
        .onAppear {
            startCount = history.items.count
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = true

    var body: some View {
        StepScaffold(title: "You're all set",
                     subtitle: "Murmur lives in your menu bar. Hold \(prefs.trigger.short) in any app to start talking.") {
            DrawnCheck(size: 76)
                .shadow(color: Brand.success.opacity(0.35), radius: 16, y: 6)
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                ShortcutList(trigger: prefs.trigger.short)
                Toggle("Open Murmur when you log in", isOn: $launchAtLogin).toggleStyle(.switch).controlSize(.small)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
        } actions: {
            Button("Start using Murmur") {
                if launchAtLogin { try? SMAppService.mainApp.register() }
                Prefs.shared.onboarded = true
                model.onFinish?()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Type-erased button style so a step can switch styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

enum Relaunch {
    static func now() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
