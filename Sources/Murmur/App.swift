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
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private let controller = AppController.shared
    private var statusMenu: StatusMenu?
    private let settings = SettingsWindowController()
    private let onboarding = OnboardingWindowController()
    private let main = MainWindowController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { NSApp.terminate(nil); return }

        NSApp.mainMenu = Self.buildMainMenu()
        statusMenu = StatusMenu(controller: controller)
        controller.onStateChange = { [weak self] in self?.statusMenu?.refresh() }
        controller.openSettings = { [weak self] tab in
            if tab == "setup" { self?.showOnboarding(step: nil) } else { self?.showSettings(tab: tab) }
        }
        onboarding.model.onFinish = { [weak self] in self?.finishOnboarding() }
        controller.start()
        Task { await Account.shared.refresh(); self.statusMenu?.refresh() }

        let prefs = Prefs.shared
        let needsSetup = !AXIsProcessTrusted() || AudioRecorder.permission != .authorized
            || (prefs.engine == .openAI && prefs.effectiveAPIKey == nil)
            || (prefs.engine == .cloud && !Account.shared.isSignedIn)
        if !prefs.onboarded || needsSetup { showOnboarding(step: prefs.onboarded ? nil : .welcome) }
    }

    /// Opening Murmur again (Spotlight, Finder, Launchpad) shows Settings. This is
    /// the way back in when a crowded menu bar hides the status icon behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMain() }
        return true
    }

    func showMain(_ page: MainNav.Page? = nil, activate: Bool = true) {
        main.show(page, activate: activate)
    }

    /// Standard app + Edit menus. Without an Edit menu, ⌘C/⌘V/⌘A do nothing in
    /// Murmur's own text fields, including when Murmur pastes a dictation into them.
    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Murmur", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettingsFromMenu), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }

    @objc func openSettingsFromMenu() { showSettings(tab: "general") }

    func showOnboarding(step: OnboardingModel.Step?, activate: Bool = true) {
        if let step {
            onboarding.show(step: step, activate: activate)
        } else {
            // Jump to the first step that still needs attention.
            let m = onboarding.model
            let first = OnboardingModel.Step.allCases.dropFirst().first { s in
                [.account, .microphone, .accessibility].contains(s) && !m.isSatisfied(s)
            } ?? .welcome
            onboarding.show(step: first, activate: activate)
        }
    }

    private func finishOnboarding() {
        onboarding.close()
        showMain(.home)
        controller.hud.show(.notice("Murmur is in your menu bar. Hold \(Prefs.shared.trigger.short) anywhere."), autoHideAfter: 3.5)
    }

    func showSettings(tab: String?, activate: Bool = true) {
        switch tab {
        case "history": showMain(.history, activate: activate); return
        case "writing", "vocabulary", "dictionary": showMain(.dictionary, activate: activate); return
        case "style": showMain(.style, activate: activate); return
        default: break
        }
        settings.show(SettingsWindowController.Pane.from(tab) ?? .general, activate: activate)
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        let quiet = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "quiet" } ?? false
        switch path.first {
        case "auth":
            Task { @MainActor in
                await Account.shared.handleAuthCallback(url)
                NSApp.activate(ignoringOtherApps: true)
                self.statusMenu?.refresh()
            }
        case "toggle": controller.toggle()
        case "start": if !controller.isRecording { controller.toggle() }
        case "stop": if controller.isRecording { controller.finish() }
        case "cancel": controller.cancelIfRecording()
        case "command": controller.startCommand()
        case "settings": showSettings(tab: path.count > 1 ? path[1] : "general", activate: !quiet)
        case "setup", "onboarding":
            let step = path.count > 1 ? OnboardingModel.Step.allCases.first { "\($0)" == path[1] } : nil
            showOnboarding(step: step ?? .welcome, activate: !quiet)
        case "home", "main":
            showMain(path.count > 1 ? MainNav.Page(rawValue: path[1]) : .home, activate: !quiet)
        case "close-settings": settings.close(); onboarding.close(); main.close()
        case "open-menu": statusMenu?.showBriefly(seconds: Double(path.count > 1 ? path[1] : "3") ?? 3)
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
        m.canRetry = state == "error"
        m.startedAt = Date().addingTimeInterval(-7)
        m.hint = state == "hint" ? "Release to insert · Space for hands-free · ⌃ for command · esc cancels" : nil
        let start = Date()
        let feed = {
            let t = Date().timeIntervalSince(start)
            let v = CGFloat(abs(sin(t * 9)) * (0.55 + 0.45 * sin(t * 1.7)))
            m.push(level: 0.2 + 0.8 * v)
        }
        switch state {
        case "processing", "command-processing": hud.show(.processing, autoHideAfter: 6)
        case "done": hud.show(.done("23 words · 1.2s"), autoHideAfter: 6)
        case "error": hud.show(.error("Can't reach the Murmur server"), autoHideAfter: 6)
        case "notice": hud.show(.notice("Didn't catch that"), autoHideAfter: 6)
        case "hide": hud.hide()
        default:
            hud.show(.listening, autoHideAfter: 6)
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 40, repeats: true) { _ in MainActor.assumeIsolated { feed() } }
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
