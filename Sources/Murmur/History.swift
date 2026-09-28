import Foundation

struct Dictation: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var raw: String
    var text: String
    var app: String?
    var mode: String          // "dictate" | "command"
    var engine: String
    var audioSeconds: Double
    var latency: Double       // seconds from key release to text inserted
    var bundleID: String? = nil
    var words: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var items: [Dictation] = []
    private let url = Secrets.dir.appendingPathComponent("history.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.iso.decode([Dictation].self, from: data) {
            items = decoded
        }
    }

    func add(_ item: Dictation) {
        items.insert(item, at: 0)
        if items.count > 500 { items.removeLast(items.count - 500) }
        save()
    }

    func clear() { items = []; save() }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(items) { try? data.write(to: url, options: .atomic) }
    }

    var totalWords: Int { items.reduce(0) { $0 + $1.words } }
    var totalSpeakingSeconds: Double { items.reduce(0) { $0 + $1.audioSeconds } }
    /// Minutes saved vs. typing at 40 wpm.
    var minutesSaved: Double {
        max(0, Double(totalWords) / 40.0 - totalSpeakingSeconds / 60.0)
    }
}

extension HistoryStore {
    /// Words per day for the last `days` days, oldest first.
    func dailyWords(days: Int) -> [(day: Date, words: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<days).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            let words = items.filter { cal.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.words }
            return (day, words)
        }
    }

    var wordsPerMinute: Int? {
        let d = items.filter { $0.mode == "dictate" }
        let minutes = d.reduce(0) { $0 + $1.audioSeconds } / 60
        guard minutes > 0.1 else { return nil }
        return Int((Double(d.reduce(0) { $0 + $1.words }) / minutes).rounded())
    }

    /// Consecutive days (ending today or yesterday) with at least one dictation.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(items.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
