import AppKit
import SwiftUI
import ApplicationServices

@main
@MainActor
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--import-env-key") {
            guard let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !k.isEmpty else {
                FileHandle.standardError.write("OPENAI_API_KEY is not set\n".data(using: .utf8)!); exit(1)
            }
            Secrets.saveOpenAIKey(k)
            print("Saved OpenAI key to \(Secrets.dir.path)/openai.key (0600)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            let app = args.firstIndex(of: "--app").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            CLI.transcribe(path: args[i + 1], bundleID: app)
        }
        for flag in ["--signup", "--login"] {
            if let i = args.firstIndex(of: flag), i + 2 < args.count {
                CLI.auth(create: flag == "--signup", email: args[i + 1], password: args[i + 2])
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let controller = AppController.shared
    private var statusMenu: StatusMenu?
    private var settingsWindow: NSWindow?
    private let settingsState = SettingsState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { NSApp.terminate(nil); return }

        statusMenu = StatusMenu(controller: controller)
        controller.onStateChange = { [weak self] in self?.statusMenu?.refresh() }
        controller.openSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        controller.start()
        Task { await Account.shared.refresh(); self.statusMenu?.refresh() }

        let prefs = Prefs.shared
        let needsSetup = !AXIsProcessTrusted() || AudioRecorder.permission != .authorized
            || (prefs.engine == .openAI && prefs.effectiveAPIKey == nil)
            || (prefs.engine == .cloud && !Account.shared.isSignedIn)
        if needsSetup { showSettings(tab: "setup") }
    }

    /// `activate: false` shows the window without taking focus (used for screenshots).
    func showSettings(tab: String?, activate: Bool = true) {
        if let tab { settingsState.tab = tab }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(state: settingsState))
            let w = NSWindow(contentViewController: host)
            w.title = "Murmur"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        guard activate else { settingsWindow?.orderFrontRegardless(); return }
        NSApp.setActivationPolicy(.regular)   // show in Dock + ⌘Tab while settings are open
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        switch path.first {
        case "toggle": controller.toggle()
        case "start": if !controller.isRecording { controller.toggle() }
        case "stop": if controller.isRecording { controller.finish() }
        case "cancel": controller.cancelIfRecording()
        case "command": controller.startCommand()
        case "settings", "setup":
            let quiet = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "quiet" } ?? false
            let tab = path.first == "setup" ? "setup" : (path.count > 1 ? path[1] : "general")
            showSettings(tab: tab, activate: !quiet)
        case "close-settings": settingsWindow?.close()
        case "demo": Demo.show(path.count > 1 ? path[1] : "listening", hud: controller.hud)
        default: break
        }
    }
}

/// Renders HUD states on demand (murmur://demo/<state>) for screenshots.
@MainActor
enum Demo {
    private static var timer: Timer?
    static func show(_ state: String, hud: HUD) {
        timer?.invalidate()
        let m = hud.model
        m.command = state == "command" || state == "command-processing"
        m.locked = state == "locked"
        m.startedAt = Date().addingTimeInterval(-7)
        m.hint = state == "hint" ? "Release to insert · Space for hands-free · ⌃ for command · Esc cancels" : nil
        var t = 0.0
        for _ in 0..<HUDModel.barCount { t += 0.08; m.push(level: CGFloat(abs(sin(t * 9)) * (0.5 + 0.5 * sin(t * 1.3)))) }
        switch state {
        case "processing", "command-processing": hud.show(.processing, autoHideAfter: 6)
        case "done": hud.show(.done("23 words · 1.2s"), autoHideAfter: 6)
        case "error": hud.show(.error("You're offline — Retry from the menu"), autoHideAfter: 6)
        case "hide": hud.hide()
        default:
            hud.show(.listening, autoHideAfter: 6)
            let start = Date().addingTimeInterval(-t)
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                let tt = Date().timeIntervalSince(start)
                let v = CGFloat(abs(sin(tt * 9)) * (0.5 + 0.5 * sin(tt * 1.3)))
                MainActor.assumeIsolated { m.push(level: v) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { timer?.invalidate() }
        }
    }
}

/// Command-line helpers for testing without the microphone:
///   Murmur --signup|--login <email> <password>
///   Murmur --transcribe <audio file> [--app <bundle id>]
@MainActor
enum CLI {
    static func auth(create: Bool, email: String, password: String) -> Never {
        Task { @MainActor in
            await Account.shared.signIn(create: create, email: email, password: password)
            if let err = Account.shared.error { fputs("error: \(err)\n", stderr); exit(1) }
            let u = Account.shared.usage
            print("signed in as \(Account.shared.email ?? "?") on \(Prefs.shared.serverURL.absoluteString) · \(u?.remainingMinutes ?? 0) of \(u?.limitMinutes ?? 0) min left")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    static func transcribe(path: String, bundleID: String?) -> Never {
        Task { @MainActor in
            do {
                let prefs = Prefs.shared
                let rec = try Recording.load(url: URL(fileURLWithPath: path))
                let t0 = Date()
                let file = try rec.writeCompressed()
                let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                let dest = Destination.classify(bundleID: bundleID, appName: bundleID, windowTitle: nil)
                print("audio:     \(String(format: "%.1f", rec.duration))s -> \(file.pathExtension) \(bytes / 1024) KB, destination \(dest)")
                if prefs.engine == .cloud {
                    guard Account.shared.isSignedIn else { throw CloudError.server(status: 401, code: "unauthorized", message: "Run --login first") }
                    let meta = DictateMeta(mode: "dictate", durationSeconds: rec.duration, language: prefs.language,
                                           vocabulary: prefs.vocabularyTerms, destination: dest.rawValue, appName: bundleID,
                                           contextBefore: nil, selection: nil, cleanup: true)
                    let r = try await Account.shared.client.dictate(fileURL: file, meta: meta)
                    print("engine:    Murmur server \(prefs.serverURL.absoluteString)")
                    print("raw:       \(r.raw)")
                    print("cleaned:   \(r.text)")
                    print("timing:    \(String(format: "%.2f", Date().timeIntervalSince(t0)))s round trip · \(r.usage.map { "\($0.remainingMinutes) of \($0.limitMinutes) free min left" } ?? "")")
                    exit(0)
                }
                guard let key = prefs.effectiveAPIKey else { throw MurmurError.noAPIKey }
                let client = OpenAIClient(apiKey: key)
                let raw = try await client.transcribe(fileURL: file, model: prefs.transcribeModel, prompt: nil, language: prefs.language)
                let t1 = Date()
                let clean = try await Cleaner(client: client).clean(raw: raw, destination: dest, appName: bundleID, contextBefore: nil, vocabulary: prefs.vocabularyTerms, model: prefs.cleanupModel)
                let t2 = Date()
                print("engine:    own OpenAI key, \(prefs.transcribeModel) + \(prefs.cleanupModel)")
                print("raw:       \(raw)")
                print("cleaned:   \(clean)")
                print("timing:    transcribe \(String(format: "%.2f", t1.timeIntervalSince(t0)))s, cleanup \(String(format: "%.2f", t2.timeIntervalSince(t1)))s")
                exit(0)
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
