import Foundation
import CoreGraphics

enum TriggerKey: String, CaseIterable, Identifiable {
    case leftOption, rightOption, fn, rightCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "fn / 🌐 Globe"
        case .leftOption: return "Left ⌥ Option"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        }
    }

    var short: String {
        switch self {
        case .fn: return "fn"
        case .leftOption: return "left ⌥"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        }
    }

    /// Glyph for key caps.
    var cap: String {
        switch self {
        case .fn: return "fn"
        case .leftOption, .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .leftOption: return 58
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .leftOption, .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }

    /// Device-dependent bit (NX_DEVICEL/RALTKEYMASK…) that tells the left key from the right one.
    var deviceMask: UInt64? {
        switch self {
        case .fn: return nil
        case .leftOption: return 0x20
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        }
    }
}

enum Engine: String, CaseIterable, Identifiable {
    case cloud, openAI, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cloud: return "Oneshot account (free)"
        case .openAI: return "Your own OpenAI key"
        case .apple: return "On this Mac (private, offline)"
        }
    }
}

/// User preferences, persisted in UserDefaults. The API key lives in a 0600 file
/// in Application Support so rebuilding the app never triggers Keychain prompts.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var trigger: TriggerKey { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    @Published var engine: Engine { didSet { d.set(engine.rawValue, forKey: "engine") } }
    @Published var transcribeModel: String { didSet { d.set(transcribeModel, forKey: "transcribeModel") } }
    @Published var cleanupEnabled: Bool { didSet { d.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var cleanupModel: String { didSet { d.set(cleanupModel, forKey: "cleanupModel") } }
    @Published var commandModel: String { didSet { d.set(commandModel, forKey: "commandModel") } }
    @Published var useContext: Bool { didSet { d.set(useContext, forKey: "useContext") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var vocabulary: String { didSet { d.set(vocabulary, forKey: "vocabulary") } }
    @Published var sounds: Bool { didSet { d.set(sounds, forKey: "sounds") } }
    /// Leave each dictation on the clipboard after inserting it (instead of restoring what was there).
    @Published var keepOnClipboard: Bool { didSet { d.set(keepOnClipboard, forKey: "keepOnClipboard") } }
    @Published var offlineFallback: Bool { didSet { d.set(offlineFallback, forKey: "offlineFallback") } }
    @Published var showIndicator: Bool { didSet { d.set(showIndicator, forKey: "showIndicator") } }
    /// Empty string = system default input.
    @Published var inputDeviceUID: String { didSet { d.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }
    @Published var apiKey: String { didSet { Secrets.saveOpenAIKey(apiKey) } }

    /// Debug/testing: when set, recordings use this audio file instead of the microphone.
    var debugAudioFile: String? { d.string(forKey: "debugAudioFile") }

    /// The Oneshot server. Baked into Info.plist at build time; overridable with
    /// `defaults write fm.oneshot.app serverURL http://localhost:8787`.
    var serverURL: URL {
        let s = d.string(forKey: "serverURL")
            ?? Bundle.main.object(forInfoDictionaryKey: "OneshotServerURL") as? String
            ?? "http://localhost:8787"
        return URL(string: s) ?? URL(string: "http://localhost:8787")!
    }

    private init() {
        Self.migrateFromMurmur(d)
        d.register(defaults: [
            "trigger": TriggerKey.leftOption.rawValue,
            "engine": Engine.cloud.rawValue,
            "transcribeModel": "gpt-4o-transcribe",
            "cleanupEnabled": true,
            "cleanupModel": "gpt-5.4-mini",
            "commandModel": "gpt-5.4-mini",
            "useContext": true,
            "language": "auto",
            "vocabulary": "",
            "sounds": true,
            "keepOnClipboard": true,
            "offlineFallback": true,
            "showIndicator": true,
        ])
        trigger = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .leftOption
        engine = Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .cloud
        transcribeModel = d.string(forKey: "transcribeModel") ?? "gpt-4o-transcribe"
        cleanupEnabled = d.bool(forKey: "cleanupEnabled")
        cleanupModel = d.string(forKey: "cleanupModel") ?? "gpt-5.4-mini"
        commandModel = d.string(forKey: "commandModel") ?? "gpt-5.4-mini"
        useContext = d.bool(forKey: "useContext")
        language = d.string(forKey: "language") ?? "auto"
        vocabulary = d.string(forKey: "vocabulary") ?? ""
        sounds = d.bool(forKey: "sounds")
        keepOnClipboard = d.bool(forKey: "keepOnClipboard")
        offlineFallback = d.bool(forKey: "offlineFallback")
        inputDeviceUID = d.string(forKey: "inputDeviceUID") ?? ""
        showIndicator = d.bool(forKey: "showIndicator")
        apiKey = Secrets.loadOpenAIKey() ?? ""
    }

    /// The app used to be called Murmur (bundle id com.brunogalvao.murmur): carry settings over once.
    private static func migrateFromMurmur(_ d: UserDefaults) {
        guard !d.bool(forKey: "migratedFromMurmur") else { return }
        if let old = d.persistentDomain(forName: "com.brunogalvao.murmur") {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromMurmur")
    }

    var vocabularyTerms: [String] {
        vocabulary
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var effectiveAPIKey: String? {
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { return k }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
        return nil
    }
}

enum Secrets {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Oneshot", isDirectory: true)
        let old = base.appendingPathComponent("Murmur", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)   // renamed from Murmur
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static var keyFile: URL { dir.appendingPathComponent("openai.key") }

    static func loadOpenAIKey() -> String? {
        guard let s = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    static func saveOpenAIKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { try? FileManager.default.removeItem(at: keyFile); return }
        FileManager.default.createFile(atPath: keyFile.path, contents: Data(k.utf8), attributes: [.posixPermissions: 0o600])
    }
}
