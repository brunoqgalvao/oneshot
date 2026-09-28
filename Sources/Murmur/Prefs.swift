import Foundation
import CoreGraphics

enum TriggerKey: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "fn / 🌐 Globe"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        }
    }

    var short: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }
}

enum Engine: String, CaseIterable, Identifiable {
    case openAI, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAI: return "OpenAI (best accuracy)"
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
    @Published var restoreClipboard: Bool { didSet { d.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var offlineFallback: Bool { didSet { d.set(offlineFallback, forKey: "offlineFallback") } }
    @Published var apiKey: String { didSet { Secrets.saveOpenAIKey(apiKey) } }

    /// Debug/testing: when set, recordings use this audio file instead of the microphone.
    var debugAudioFile: String? { d.string(forKey: "debugAudioFile") }

    private init() {
        d.register(defaults: [
            "trigger": TriggerKey.fn.rawValue,
            "engine": Engine.openAI.rawValue,
            "transcribeModel": "gpt-4o-transcribe",
            "cleanupEnabled": true,
            "cleanupModel": "gpt-5.4-mini",
            "commandModel": "gpt-5.4-mini",
            "useContext": true,
            "language": "auto",
            "vocabulary": "",
            "sounds": true,
            "restoreClipboard": true,
            "offlineFallback": true,
        ])
        trigger = TriggerKey(rawValue: d.string(forKey: "trigger") ?? "") ?? .fn
        engine = Engine(rawValue: d.string(forKey: "engine") ?? "") ?? .openAI
        transcribeModel = d.string(forKey: "transcribeModel") ?? "gpt-4o-transcribe"
        cleanupEnabled = d.bool(forKey: "cleanupEnabled")
        cleanupModel = d.string(forKey: "cleanupModel") ?? "gpt-5.4-mini"
        commandModel = d.string(forKey: "commandModel") ?? "gpt-5.4-mini"
        useContext = d.bool(forKey: "useContext")
        language = d.string(forKey: "language") ?? "auto"
        vocabulary = d.string(forKey: "vocabulary") ?? ""
        sounds = d.bool(forKey: "sounds")
        restoreClipboard = d.bool(forKey: "restoreClipboard")
        offlineFallback = d.bool(forKey: "offlineFallback")
        apiKey = Secrets.loadOpenAIKey() ?? ""
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
        let url = base.appendingPathComponent("Murmur", isDirectory: true)
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
