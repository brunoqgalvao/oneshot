import SwiftUI
import AVFoundation
import Speech
import ServiceManagement
import ApplicationServices

final class SettingsState: ObservableObject {
    @Published var tab = "setup"
}

final class PermissionsModel: ObservableObject {
    @Published var mic = AudioRecorder.permission
    @Published var ax = AXIsProcessTrusted()
    @Published var speech = AppleTranscriber.status
    @Published var fnUsage: Int? = nil
    @Published var hotkeyActive = false
    private var timer: Timer?

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        mic = AudioRecorder.permission
        ax = AXIsProcessTrusted()
        speech = AppleTranscriber.status
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        fnUsage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        hotkeyActive = MainActor.assumeIsolated { AppController.shared.hotkeyActive }
    }
}

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

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        TabView(selection: $state.tab) {
            SetupView().tabItem { Label("Setup", systemImage: "checklist") }.tag("setup")
            GeneralView().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AIView().tabItem { Label("AI", systemImage: "sparkles") }.tag("ai")
            HistoryView().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag("history")
        }
        .frame(width: 640, height: 600)
    }
}

// MARK: Setup

struct SetupView: View {
    @StateObject private var perms = PermissionsModel()
    @ObservedObject private var prefs = Prefs.shared
    @State private var tryText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Murmur").font(.system(size: 22, weight: .semibold))
                        Text("Talk instead of type, in any app.").foregroundColor(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    StepRow(done: perms.mic == .authorized, title: "Microphone",
                            detail: "So Murmur can hear you while you hold the key.",
                            button: perms.mic == .notDetermined ? "Allow" : "Open Settings") {
                        if perms.mic == .notDetermined { AudioRecorder.requestPermission { _ in perms.refresh() } } else { SystemPane.open("mic") }
                    }
                    Divider()
                    StepRow(done: perms.ax && perms.hotkeyActive, title: "Accessibility",
                            detail: perms.ax && !perms.hotkeyActive
                                ? "Granted — quit and reopen Murmur to activate the key."
                                : "Lets Murmur notice the dictation key and paste into the app you're using.",
                            button: "Open Settings") {
                        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(opts)
                        SystemPane.open("ax")
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        StatusIcon(done: prefs.effectiveAPIKey != nil)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("OpenAI API key").font(.system(size: 13, weight: .semibold))
                            Text("Used for transcription and cleanup. Stored only on this Mac.").font(.system(size: 12)).foregroundColor(.secondary)
                            SecureField("sk-…", text: $prefs.apiKey).textFieldStyle(.roundedBorder)
                        }
                    }.padding(.vertical, 12)
                    if prefs.trigger == .fn {
                        Divider()
                        StepRow(done: perms.fnUsage == 0, optional: true, title: "Globe key",
                                detail: "Set “Press 🌐 key to” → Do Nothing, so holding fn doesn't also open the emoji picker. Or pick Right ⌥ in General.",
                                button: "Keyboard Settings") { SystemPane.open("keyboard") }
                    }
                    Divider()
                    StepRow(done: perms.speech == .authorized, optional: true, title: "Offline fallback",
                            detail: "Transcribe on this Mac when you're offline or OpenAI is unreachable.",
                            button: perms.speech == .notDetermined ? "Allow" : "Open Settings") {
                        if perms.speech == .notDetermined { AppleTranscriber.requestPermission { _ in perms.refresh() } } else { SystemPane.open("speech") }
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Try it").font(.system(size: 13, weight: .semibold))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $tryText)
                            .font(.system(size: 13))
                            .frame(height: 90)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                        if tryText.isEmpty {
                            Text("Click here, hold \(prefs.trigger.short) and say something…")
                                .foregroundColor(.secondary).font(.system(size: 13))
                                .padding(.horizontal, 12).padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
                }

                CheatSheet(trigger: prefs.trigger.short)
            }
            .padding(24)
        }
        .onAppear { perms.startPolling() }
        .onDisappear { perms.stopPolling() }
    }
}

struct CheatSheet: View {
    let trigger: String
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            row("Hold \(trigger)", "Dictate, release to insert")
            row("Double-tap \(trigger)  or  \(trigger) + Space", "Hands-free; tap \(trigger) again to finish")
            row("Hold ⌃ Control while dictating", "Command mode: rewrite the selection, or write something new")
            row("Esc", "Cancel")
        }
        .font(.system(size: 12))
    }
    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            Text(v).foregroundColor(.secondary)
        }
    }
}

struct StatusIcon: View {
    let done: Bool
    var optional = false
    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "circle"))
            .font(.system(size: 17))
            .foregroundColor(done ? .green : .secondary)
            .frame(width: 20)
    }
}

struct StepRow: View {
    let done: Bool
    var optional = false
    let title: String
    let detail: String
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(done: done, optional: optional)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if optional { Text("Optional").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07))) }
                }
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { Button(button, action: action).controlSize(.small) }
        }
        .padding(.vertical, 12)
    }
}

// MARK: General

struct GeneralView: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $prefs.trigger) {
                    ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                }
                CheatSheet(trigger: prefs.trigger.short).padding(.vertical, 4)
            }
            Section("Transcription") {
                Picker("Engine", selection: $prefs.engine) {
                    ForEach(Engine.allCases) { Text($0.label).tag($0) }
                }
                Picker("Language", selection: $prefs.language) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("Português").tag("pt")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                    Text("Deutsch").tag("de")
                    Text("Italiano").tag("it")
                }
                Toggle("Fall back to on-device transcription when offline", isOn: $prefs.offlineFallback)
            }
            Section("Behavior") {
                Toggle("Play sounds", isOn: $prefs.sounds)
                Toggle("Restore clipboard after inserting", isOn: $prefs.restoreClipboard)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { NSLog("Launch at login failed: \(error)"); launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: AI

struct AIView: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $prefs.apiKey)
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { test() }.disabled(testing || prefs.effectiveAPIKey == nil)
                    if let testResult { Text(testResult).font(.system(size: 12)).foregroundColor(.secondary) }
                }
                Picker("Speech model", selection: $prefs.transcribeModel) {
                    Text("gpt-4o-transcribe").tag("gpt-4o-transcribe")
                    Text("gpt-4o-mini-transcribe (faster)").tag("gpt-4o-mini-transcribe")
                    Text("gpt-transcribe").tag("gpt-transcribe")
                    Text("whisper-1").tag("whisper-1")
                }
            }
            Section {
                Toggle("Clean up transcripts", isOn: $prefs.cleanupEnabled)
                Picker("Cleanup model", selection: $prefs.cleanupModel) {
                    Text("gpt-5.4-mini").tag("gpt-5.4-mini")
                    Text("gpt-5.4-nano (fastest)").tag("gpt-5.4-nano")
                    Text("gpt-4.1-mini").tag("gpt-4.1-mini")
                    Text("gpt-4.1-nano").tag("gpt-4.1-nano")
                }.disabled(!prefs.cleanupEnabled)
                Picker("Command model", selection: $prefs.commandModel) {
                    Text("gpt-5.4-mini").tag("gpt-5.4-mini")
                    Text("gpt-5.4").tag("gpt-5.4")
                    Text("gpt-4.1-mini").tag("gpt-4.1-mini")
                }
                Toggle("Use text around the cursor for context", isOn: $prefs.useContext)
            } header: { Text("Cleanup") } footer: {
                Text("Removes filler words, applies self-corrections (“at 2, actually 3”), fixes punctuation and adapts formatting to the app you're in. Context sends up to 600 characters before the cursor; password fields are never read.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Section {
                TextEditor(text: $prefs.vocabulary)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
            } header: { Text("Vocabulary") } footer: {
                Text("Names, products and jargon, one per line or comma-separated. Used to bias transcription and fix spellings.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        guard let key = prefs.effectiveAPIKey else { return }
        testing = true
        testResult = nil
        let start = Date()
        Task { @MainActor in
            do {
                _ = try await OpenAIClient(apiKey: key).chat(model: prefs.cleanupModel, system: "Reply with OK.", user: "ping", maxTokens: 20)
                testResult = "Connected · \(String(format: "%.1f", Date().timeIntervalSince(start)))s"
            } catch {
                testResult = AppController.describe(error)
            }
            testing = false
        }
    }
}

// MARK: History

struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                Stat(value: "\(history.totalWords)", label: "words dictated")
                Stat(value: "\(history.items.count)", label: "dictations")
                Stat(value: String(format: "%.0f", history.minutesSaved), label: "minutes saved vs. typing")
                Spacer()
                Button("Clear") { history.clear() }.disabled(history.items.isEmpty)
            }
            .padding(20)
            Divider()
            if history.items.isEmpty {
                Spacer()
                Text("Your dictations will show up here.").foregroundColor(.secondary)
                Spacer()
            } else {
                List(history.items) { d in HistoryRow(d: d) }
                    .listStyle(.inset)
            }
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let d: Dictation
    @State private var showRaw = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if d.mode == "command" { Image(systemName: "sparkles").foregroundColor(.purple).font(.system(size: 10)) }
                Text(d.app ?? "Unknown app").font(.system(size: 11, weight: .medium))
                Text("·").foregroundColor(.secondary)
                Text(d.date, style: .time).font(.system(size: 11)).foregroundColor(.secondary)
                Text("· \(String(format: "%.1f", d.audioSeconds))s audio · \(String(format: "%.1f", d.latency))s to insert · \(d.engine)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button { showRaw.toggle() } label: { Text(showRaw ? "Cleaned" : "Raw").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                Button { Paster.copy(d.text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
            }
            Text(showRaw ? d.raw : d.text)
                .font(.system(size: 13))
                .foregroundColor(showRaw ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
