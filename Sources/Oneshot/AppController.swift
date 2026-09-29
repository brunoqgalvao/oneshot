import AppKit
import Combine
import ApplicationServices

/// Owns the dictation lifecycle: key press -> record -> transcribe -> clean -> paste.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let prefs = Prefs.shared
    let history = HistoryStore.shared
    let pending = PendingStore.shared
    let hud = HUD()
    let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let apple = AppleTranscriber()

    @Published private(set) var isRecording = false
    @Published private(set) var inFlight = 0
    @Published private(set) var hotkeyActive = false
    @Published private(set) var canRetry = false
    /// Saved recordings being retried right now (drives the History spinner).
    @Published private(set) var retrying: Set<UUID> = []
    struct DictationEvent: Equatable { let id = UUID(); let locked: Bool; let command: Bool }
    /// The last dictation that finished successfully (drives the onboarding lessons).
    @Published private(set) var lastDictation: DictationEvent?
    /// Mirrors command mode of the current recording.
    @Published private(set) var commandActive = false
    /// True while the dictation key is physically held (drives the practice key cap).
    @Published private(set) var triggerHeld = false
    var onStateChange: (() -> Void)?
    var openSettings: ((String?) -> Void)?

    struct Session {
        var startedAt = Date()
        var pressAt = Date()
        var locked: Bool
        var command: Bool
        var focus: FocusSnapshot
        var fakeAudio: URL?
    }

    private var session: Session? { didSet { sessionLocked = session?.locked ?? false } }
    @Published private(set) var sessionLocked = false
    private var pendingTap: DispatchWorkItem?
    private var showWork: DispatchWorkItem?
    private var fakeTimer: Timer?
    private var trustTimer: Timer?
    private var lastLevelAt = Date.distantPast
    /// The saved recording behind the HUD's Retry button.
    private var lastFailure: UUID?
    private var capTimer: Timer?
    private var bag = Set<AnyCancellable>()

    // MARK: Setup

    func start() {
        hotkey.onPress = { [weak self] in self?.triggerHeld = true; self?.triggerPressed() }
        hotkey.onRelease = { [weak self] in self?.triggerHeld = false; self?.triggerReleased() }
        hotkey.onSpaceWhileHeld = { [weak self] in self?.lockFromSpace() ?? false }
        hotkey.onEscape = { [weak self] in self?.escape() ?? false }
        hotkey.onOtherKeyWhileHeld = { [weak self] in self?.otherKeyWhileHeld() }
        hotkey.onControlDown = { [weak self] in self?.enableCommandMode() }
        hud.model.onStop = { [weak self] in self?.finish() }
        hud.model.onCancel = { [weak self] in self?.cancel(silent: false) }
        hud.model.onRetry = { [weak self] in self?.retryLast() }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.pushLevel(CGFloat(level)) }
        }
        prefs.$trigger.sink { [weak self] t in self?.hotkey.trigger = t }.store(in: &bag)
        installHotkey()
    }

    /// The event tap needs Accessibility. Keep trying until the user grants it.
    func installHotkey() {
        if hotkey.start() { hotkeyActive = true; onStateChange?(); return }
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if AXIsProcessTrusted(), self.hotkey.start() {
                    t.invalidate()
                    self.hotkeyActive = true
                    self.onStateChange?()
                }
            }
        }
    }

    // MARK: Key handling

    private func triggerPressed() {
        if var s = session {
            if s.locked { finish(); return }
            if let tap = pendingTap {   // second tap of a double-tap -> hands-free
                tap.cancel(); pendingTap = nil
                s.locked = true
                session = s
                hud.model.hint = nil
                hud.setLocked(true)
                if !hud.isVisible { hud.show(.listening) }
            }
            return
        }
        begin(locked: false)
    }

    private func triggerReleased() {
        guard let s = session, !s.locked else { return }
        if Date().timeIntervalSince(s.pressAt) < 0.28 {
            // A quick tap: wait to see if it's a double-tap before discarding.
            let work = DispatchWorkItem { [weak self] in
                self?.pendingTap = nil
                self?.cancel(silent: true)
            }
            pendingTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.33, execute: work)
        } else {
            finish()
        }
    }

    private func lockFromSpace() -> Bool {
        guard var s = session, !s.locked else { return false }
        s.locked = true
        session = s
        hud.model.hint = nil
        hud.setLocked(true)
        if !hud.isVisible { showWork?.perform() }
        return true
    }

    private func escape() -> Bool {
        guard session != nil else { return false }
        cancel(silent: false)
        return true
    }

    private func otherKeyWhileHeld() {
        // fn+arrow, ⌥+letter...: the key was used as a modifier, not to dictate.
        guard let s = session, !s.locked, Date().timeIntervalSince(s.startedAt) < 0.8 else { return }
        cancel(silent: true)
    }

    private func enableCommandMode() {
        guard var s = session, !s.command else { return }
        s.command = true
        session = s
        commandActive = true
        hud.setCommand(true)
        hud.model.hint = (s.focus.selectedText ?? "").isEmpty ? "Command: say what to write" : "Command: say how to change the selection"
    }

    // MARK: Public actions (menu, URL scheme)

    func toggle() {
        if session != nil { finish() } else { begin(locked: true) }
    }

    func startCommand() {
        if session != nil { return }
        begin(locked: true)
        enableCommandMode()
    }

    func cancelIfRecording() { if session != nil { cancel(silent: false) } }

    func retryLast() {
        guard let id = lastFailure, let p = pending.item(id) else { return }
        lastFailure = nil
        canRetry = false
        hud.model.command = p.command
        hud.model.canRetry = false
        hud.show(.processing)
        run(pending.recording(for: p), session(for: p), releasedAt: Date(), pendingID: id, deliver: .paste)
    }

    /// Tries a saved recording again from History. The result goes to the clipboard and History,
    /// since the field it was meant for is long gone.
    func retry(_ id: UUID) {
        guard let p = pending.item(id), !retrying.contains(id) else { return }
        if lastFailure == id { lastFailure = nil; canRetry = false }
        hud.model.command = p.command
        hud.model.canRetry = false
        hud.show(.processing)
        run(pending.recording(for: p), session(for: p), releasedAt: Date(), pendingID: id, deliver: .copy)
    }

    private func session(for p: PendingDictation) -> Session {
        let focus = FocusSnapshot(appName: p.app, bundleID: p.bundleID, textBeforeCursor: p.contextBefore, selectedText: p.selection)
        return Session(locked: true, command: p.command, focus: focus, fakeAudio: nil)
    }

    func pasteLast() {
        guard let last = history.items.first else { return }
        insert(last.text)
    }

    // MARK: Lifecycle

    private func begin(locked: Bool) {
        guard session == nil else { return }
        switch prefs.engine {
        case .cloud where !Account.shared.isSignedIn:
            flash(.error("Sign in to Oneshot (it's free) to start dictating"), sound: true)
            openSettings?("setup")
            return
        case .openAI where prefs.effectiveAPIKey == nil && !appleFallbackOK:
            flash(.error("Add an OpenAI API key in Settings"), sound: true)
            openSettings?("ai")
            return
        default: break
        }
        let focus = FocusSnapshot.capture(readText: true)
        if focus.isSecure {
            flash(.notice("Dictation is off in password fields"), sound: false)
            return
        }

        var fake: URL?
        if let path = prefs.debugAudioFile, FileManager.default.fileExists(atPath: path) {
            fake = URL(fileURLWithPath: path)
        } else {
            switch AudioRecorder.permission {
            case .notDetermined:
                AudioRecorder.requestPermission { _ in }
                flash(.notice("Allow microphone access, then try again"), sound: false)
                return
            case .denied, .restricted:
                flash(.error("Microphone access is off — see Setup"), sound: true)
                openSettings?("setup")
                return
            default: break
            }
            do { try recorder.start() } catch {
                flash(.error(error.localizedDescription), sound: true)
                return
            }
        }

        session = Session(locked: locked, command: false, focus: focus, fakeAudio: fake)
        commandActive = false
        isRecording = true
        onStateChange?()
        switch prefs.engine {
        case .cloud: CloudClient.prewarm(prefs.serverURL)
        case .openAI: OpenAIClient.prewarm()
        case .apple: break
        }
        if fake != nil { startFakeLevels() }
        // Recordings stop by themselves at the 3-hour limit.
        capTimer?.invalidate()
        capTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session != nil, self.recorder.elapsed >= Recording.maxDuration else { return }
                self.finish()
            }
        }

        let m = hud.model
        m.canRetry = false
        m.resetLevels()
        m.locked = locked
        m.command = false
        m.startedAt = Date()
        m.hint = history.items.count < 5 && !locked ? "Release to insert · Space for hands-free · ⌃ for command · Esc cancels" : nil

        // Show a beat later so fn+key combos and accidental taps don't flash the HUD.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session != nil else { return }
            self.hud.show(.listening)
            Sound.play(.start)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (locked ? 0 : 0.14), execute: work)
    }

    private func stopCapture(_ s: Session) -> Recording {
        showWork?.cancel(); showWork = nil
        pendingTap?.cancel(); pendingTap = nil
        fakeTimer?.invalidate(); fakeTimer = nil
        capTimer?.invalidate(); capTimer = nil
        if let fake = s.fakeAudio { return (try? Recording.load(url: fake)) ?? Recording(parts: [], duration: 0, peak: 0) }
        return recorder.stop()
    }

    private func cancel(silent: Bool) {
        guard let s = session else { return }
        session = nil
        isRecording = false
        stopCapture(s).discard()
        onStateChange?()
        if silent || !hud.isVisible { hud.hide() } else { flash(.notice("Cancelled"), sound: false) }
    }

    func finish() {
        guard let s = session else { return }
        session = nil
        isRecording = false
        let wasVisible = hud.isVisible
        let rec = stopCapture(s)
        onStateChange?()
        if wasVisible { Sound.play(.stop) }

        if rec.duration < 0.3 { rec.discard(); hud.hide(); return }
        if rec.peak < 0.006 {
            rec.discard()
            flash(.notice("Didn't hear anything — is the mic muted?"), sound: false)
            return
        }
        hud.model.canRetry = false
        hud.show(.processing)
        run(rec, s, releasedAt: Date())
    }

    enum Deliver { case paste, copy }

    private func run(_ rec: Recording, _ s: Session, releasedAt: Date, pendingID: UUID? = nil, deliver: Deliver = .paste) {
        inFlight += 1
        if let pendingID { retrying.insert(pendingID) }
        onStateChange?()
        Task { @MainActor in
            defer {
                self.inFlight -= 1
                if let pendingID { self.retrying.remove(pendingID) }
                self.onStateChange?()
            }
            await self.process(rec, s, releasedAt: releasedAt, pendingID: pendingID, deliver: deliver)
        }
    }

    private struct Outcome { var raw: String; var text: String; var mode: String; var engine: String }

    private func process(_ rec: Recording, _ s: Session, releasedAt: Date, pendingID: UUID?, deliver: Deliver) async {
        // The audio is done with: a fresh recording's temp folder, or a saved one that finally went through.
        func done() { if let pendingID { pending.remove(pendingID) } else { rec.discard() } }
        // Nothing recognized: a fresh recording is dropped, but a saved one is kept for the user to decide.
        func nothingHeard() {
            if let pendingID {
                pending.failedAgain(pendingID, error: "No speech found")
                flash(.notice("No speech found — kept in History"), sound: false)
            } else {
                rec.discard()
                flash(.notice("Didn't catch that"), sound: false)
            }
        }
        do {
            var selection = s.focus.selectedText
            // AX couldn't see the field (common in Electron apps): read the selection via ⌘C.
            if pendingID == nil, s.command, (selection ?? "").isEmpty, s.focus.role == nil, AXIsProcessTrusted(),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == s.focus.pid {
                selection = await Paster.copySelection()
            }

            let out: Outcome
            switch prefs.engine {
            case .cloud: out = try await viaCloud(rec: rec, s: s, selection: selection)
            case .openAI, .apple: out = try await viaDirect(rec: rec, s: s, selection: selection)
            }

            let raw = out.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || Hallucination.isLikely(raw, rec) {
                nothingHeard()
                return
            }
            var text = out.text.isEmpty ? raw : out.text
            if !s.command && deliver == .paste { text = Spacing.join(text, after: s.focus.textBeforeCursor) }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                nothingHeard(); return
            }

            // Debug runs (fake audio) only paste into TextEdit, so a test can never type into real work.
            let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let debugUnsafe = s.fakeAudio != nil && frontID != "com.apple.TextEdit" && frontID != Bundle.main.bundleIdentifier
            let pasted = debugUnsafe || deliver == .copy ? { Paster.copy(text); return false }() : insert(text)
            let latency = Date().timeIntervalSince(releasedAt)
            history.add(Dictation(raw: raw, text: text.trimmingCharacters(in: .whitespaces), app: s.focus.appName,
                                  mode: out.mode, engine: out.engine, audioSeconds: rec.duration, latency: latency,
                                  bundleID: s.focus.bundleID))
            done()
            lastDictation = DictationEvent(locked: s.locked, command: s.command)
            if pendingID == nil || lastFailure == pendingID { lastFailure = nil; canRetry = false }
            if !isRecording {
                let words = text.split(whereSeparator: { $0.isWhitespace }).count
                let what = pasted ? (out.mode == "command" ? "Replaced" : "\(words) word\(words == 1 ? "" : "s")") : "Copied — press ⌘V"
                hud.show(.done("\(what) · \(String(format: "%.1f", latency))s"), autoHideAfter: pasted ? 1.1 : 2.5)
            }
        } catch {
            NSLog("Oneshot failed: \(error)")
            // Keep the audio so nothing said is lost; it can be tried again from the HUD, the menu or History.
            let message = Self.describe(error)
            let savedID: UUID?
            if let pendingID { pending.failedAgain(pendingID, error: message); savedID = pendingID }
            else { savedID = pending.add(rec, focus: s.focus, command: s.command, error: message)?.id }
            if let e = error as? CloudError {
                if e.status == 401 {
                    Account.shared.sessionExpired()
                    flash(.error("Please sign in again. Your recording is saved in History."), sound: true, seconds: 4)
                    openSettings?("setup")
                    return
                }
                if ["daily_limit", "at_capacity", "too_long", "update_required"].contains(e.code) {
                    let saved = savedID != nil && e.code != "too_long" ? " Saved in History to try later." : ""
                    flash(.error(e.localizedDescription + saved), sound: true, seconds: 5)
                    return
                }
            }
            lastFailure = savedID
            canRetry = savedID != nil
            flash(.error(message), sound: true, seconds: 6, retry: savedID != nil)
        }
    }

    private var appleFallbackOK: Bool { prefs.offlineFallback && AppleTranscriber.status == .authorized }

    /// One request to the Oneshot server: it transcribes and cleans up.
    private func viaCloud(rec: Recording, s: Session, selection: String?) async throws -> Outcome {
        let meta = DictateMeta(
            mode: s.command ? "command" : "dictate",
            durationSeconds: rec.duration,
            language: prefs.language,
            vocabulary: prefs.vocabularyTerms,
            destination: s.focus.destination.rawValue,
            appName: s.focus.appName,
            contextBefore: prefs.useContext ? s.focus.textBeforeCursor : nil,
            selection: s.command ? selection : nil,
            cleanup: prefs.cleanupEnabled)
        do {
            let r = try await Account.shared.client.dictate(fileURLs: rec.parts, meta: meta)
            Account.shared.update(usage: r.usage)
            onStateChange?()
            return Outcome(raw: r.raw, text: r.text, mode: r.mode, engine: "oneshot")
        } catch let e as URLError where appleFallbackOK && !s.command {
            NSLog("Oneshot: server unreachable (\(e.code.rawValue)), transcribing on-device")
            let raw = try await appleTranscribe(rec.parts)
            return Outcome(raw: raw, text: raw, mode: "dictate", engine: "apple (offline fallback)")
        }
    }

    /// Own OpenAI key or on-device engine: transcribe here, then clean up with OpenAI if a key is set.
    private func viaDirect(rec: Recording, s: Session, selection: String?) async throws -> Outcome {
        let (raw0, engineName) = try await transcribe(parts: rec.parts)
        let raw = raw0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return Outcome(raw: "", text: "", mode: "dictate", engine: engineName) }
        let client = prefs.effectiveAPIKey.map { OpenAIClient(apiKey: $0) }
        if s.command, let client {
            let text = try await Cleaner(client: client).command(
                instruction: raw, selection: selection, destination: s.focus.destination,
                appName: s.focus.appName, model: prefs.commandModel)
            return Outcome(raw: raw, text: text, mode: "command", engine: engineName)
        }
        var text = raw
        if prefs.cleanupEnabled, let client {
            do {
                let cleaned = try await Cleaner(client: client).clean(
                    raw: raw, destination: s.focus.destination, appName: s.focus.appName,
                    contextBefore: prefs.useContext ? s.focus.textBeforeCursor : nil,
                    vocabulary: prefs.vocabularyTerms, model: prefs.cleanupModel)
                if !cleaned.isEmpty, !Cleaner.looksLikeDrift(raw: raw, cleaned: cleaned) { text = cleaned }
            } catch {
                NSLog("Oneshot cleanup failed, using raw transcript: \(error)")
            }
        }
        return Outcome(raw: raw, text: text, mode: "dictate", engine: engineName)
    }

    /// Transcribes every part (in parallel with OpenAI, in order on-device) and joins the text.
    private func transcribe(parts: [URL]) async throws -> (String, String) {
        let vocab = prefs.vocabularyTerms
        if prefs.engine == .apple {
            return (try await appleTranscribe(parts), "apple")
        }
        guard let key = prefs.effectiveAPIKey else {
            if appleFallbackOK { return (try await appleTranscribe(parts), "apple") }
            throw OneshotError.noAPIKey
        }
        do {
            let prompt = vocab.isEmpty ? nil : "Vocabulary: " + vocab.joined(separator: ", ")
            let client = OpenAIClient(apiKey: key)
            let model = prefs.transcribeModel, language = prefs.language
            let texts = try await withThrowingTaskGroup(of: (Int, String).self) { group -> [String] in
                for (i, url) in parts.enumerated() {
                    group.addTask {
                        func once() async throws -> String {
                            do { return try await client.transcribe(fileURL: url, model: model, prompt: prompt, language: language) }
                            catch { return try await client.transcribe(fileURL: url, model: model, prompt: prompt, language: language) }  // one retry
                        }
                        let first = try await once()
                        // gpt-4o-transcribe occasionally returns only a fragment of a part; ~3 KB/s of AAC per second of audio.
                        let seconds = Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 3000
                        let words = { (s: String) in s.split(whereSeparator: { $0.isWhitespace }).count }
                        if parts.count > 1, seconds > 15, Double(words(first)) < seconds * 0.6,
                           let second = try? await once(), words(second) > words(first) {
                            return (i, second)
                        }
                        return (i, first)
                    }
                }
                var out = Array(repeating: "", count: parts.count)
                for try await (i, t) in group { out[i] = t }
                return out
            }
            return (texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " "), prefs.transcribeModel)
        } catch let e as URLError where appleFallbackOK {
            NSLog("Oneshot: network error \(e.code.rawValue), falling back to on-device")
            return (try await appleTranscribe(parts), "apple (offline fallback)")
        }
    }

    private func appleTranscribe(_ parts: [URL]) async throws -> String {
        var texts: [String] = []
        for url in parts {
            let t = try await apple.transcribe(url: url, language: prefs.language, vocabulary: prefs.vocabularyTerms)
            if !t.isEmpty { texts.append(t) }
        }
        return texts.joined(separator: " ")
    }

    @discardableResult
    private func insert(_ text: String) -> Bool {
        // Dictating into Oneshot's own window: type straight into the focused field.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let field = NSApp.keyWindow?.firstResponder as? NSTextView, field.isEditable {
            field.insertText(text, replacementRange: field.selectedRange())
            if prefs.keepOnClipboard { Paster.copy(text) }
            return true
        }
        if AXIsProcessTrusted() {
            Paster.paste(text, keepOnClipboard: prefs.keepOnClipboard)
            return true
        }
        Paster.copy(text)
        return false
    }

    // MARK: Helpers

    private func flash(_ phase: HUDModel.Phase, sound: Bool, seconds: Double = 2.2, retry: Bool = false) {
        if sound { Sound.play(.error) }
        hud.model.canRetry = retry
        if case .notice = phase { hud.show(phase, autoHideAfter: 1.6) } else { hud.show(phase, autoHideAfter: seconds) }
    }

    private func pushLevel(_ level: CGFloat) {
        guard session != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelAt) > 1.0 / 40 else { return }
        lastLevelAt = now
        hud.model.push(level: level)
    }

    private func startFakeLevels() {
        let start = Date()
        fakeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            let t = Date().timeIntervalSince(start)
            let syllables = abs(sin(t * 9)) * (0.55 + 0.45 * sin(t * 1.7))
            MainActor.assumeIsolated { self?.hud.model.push(level: CGFloat(max(0.05, syllables))) }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "You're offline"
            case .cannotFindHost, .cannotConnectToHost: return "Can't reach the Oneshot server"
            case .timedOut: return "The request timed out"
            default: return "Network error"
            }
        }
        if let e = error as? CloudError { return e.localizedDescription }
        if let e = error as? OneshotError, case .http(let code, let msg) = e {
            if code == 401 { return "OpenAI rejected the API key" }
            if code == 429 { return "OpenAI rate limit or quota reached" }
            return "OpenAI \(code): " + String(msg.prefix(80))
        }
        return String(error.localizedDescription.prefix(100))
    }
}

/// Speech models sometimes invent a phrase when fed near-silence.
enum Hallucination {
    private static let phrases: Set<String> = [
        "thank you.", "thank you", "thanks for watching!", "thanks for watching.", "you", "bye.", "bye",
        "obrigado.", "obrigada.", "obrigado", "tchau.", "legendas pela comunidade amara.org",
        "subtitles by the amara.org community", "♪", "...", ".",
    ]
    static func isLikely(_ text: String, _ rec: Recording) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return phrases.contains(t) && (rec.peak < 0.05 || rec.duration < 1.2)
    }
}
