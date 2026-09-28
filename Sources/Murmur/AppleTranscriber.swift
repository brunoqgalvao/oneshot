import Foundation
import Speech

/// On-device transcription with Apple's Speech framework. Used as the offline
/// engine and as a fallback when the network fails.
final class AppleTranscriber {
    private var task: SFSpeechRecognitionTask?

    static var status: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { s in DispatchQueue.main.async { done(s == .authorized) } }
    }

    static func locale(for language: String) -> Locale {
        switch language {
        case "auto": return Locale.current
        case "pt": return Locale(identifier: "pt-BR")
        case "en": return Locale(identifier: "en-US")
        default: return Locale(identifier: language)
        }
    }

    func transcribe(url: URL, language: String, vocabulary: [String]) async throws -> String {
        guard Self.status == .authorized else { throw MurmurError.speechUnavailable("Allow Speech Recognition for offline mode") }
        guard let rec = SFSpeechRecognizer(locale: Self.locale(for: language)), rec.isAvailable else {
            throw MurmurError.speechUnavailable("On-device speech isn't available for this language")
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        req.contextualStrings = vocabulary
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            task = rec.recognitionTask(with: req) { result, error in
                if finished { return }
                if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    finished = true
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) {
                        cont.resume(returning: "")   // no speech
                    } else {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }
}
