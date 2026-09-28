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

        let needsSetup = !AXIsProcessTrusted() || AudioRecorder.permission != .authorized
            || (Prefs.shared.engine == .openAI && Prefs.shared.effectiveAPIKey == nil)
        if needsSetup { showSettings(tab: "setup") }
    }

    func showSettings(tab: String?) {
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
        case "settings": showSettings(tab: path.count > 1 ? path[1] : "general")
        case "setup": showSettings(tab: "setup")
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

/// murmur --transcribe <audio file> [--app <bundle id>]: runs the same pipeline
/// without the microphone or pasting, printing each stage with timings.
@MainActor
enum CLI {
    static func transcribe(path: String, bundleID: String?) -> Never {
        Task { @MainActor in
            do {
                let prefs = Prefs.shared
                guard let key = prefs.effectiveAPIKey else { throw MurmurError.noAPIKey }
                let rec = try Recording.load(url: URL(fileURLWithPath: path))
                let t0 = Date()
                let file = try rec.writeCompressed()
                let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                let client = OpenAIClient(apiKey: key)
                let raw = try await client.transcribe(fileURL: file, model: prefs.transcribeModel, prompt: nil, language: prefs.language)
                let t1 = Date()
                let dest = Destination.classify(bundleID: bundleID, appName: bundleID, windowTitle: nil)
                let clean = try await Cleaner(client: client).clean(raw: raw, destination: dest, appName: bundleID, contextBefore: nil, vocabulary: prefs.vocabularyTerms, model: prefs.cleanupModel)
                let t2 = Date()
                print("audio:     \(String(format: "%.1f", rec.duration))s -> \(file.pathExtension) \(bytes / 1024) KB")
                print("model:     \(prefs.transcribeModel) + \(prefs.cleanupModel), destination \(dest)")
                print("raw:       \(raw)")
                print("cleaned:   \(clean)")
                print("timing:    transcribe \(String(format: "%.2f", t1.timeIntervalSince(t0)))s, cleanup \(String(format: "%.2f", t2.timeIntervalSince(t1)))s")
                exit(0)
            } catch {
                FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
