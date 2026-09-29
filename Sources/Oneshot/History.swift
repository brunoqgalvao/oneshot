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

// MARK: - Recordings that didn't go through

/// A recording that couldn't be transcribed. The audio stays on disk so it can be tried again later.
struct PendingDictation: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var app: String?
    var bundleID: String?
    var command: Bool
    var contextBefore: String?
    var selection: String?
    var duration: Double
    var peak: Float
    var parts: [String]       // file names inside the item's folder, in order
    var error: String
    var attempts = 1
}

final class PendingStore: ObservableObject {
    static let shared = PendingStore()
    static let maxItems = 20
    @Published private(set) var items: [PendingDictation] = []
    private let root = Secrets.dir.appendingPathComponent("pending", isDirectory: true)
    private var index: URL { root.appendingPathComponent("pending.json") }

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index),
           let decoded = try? JSONDecoder.iso.decode([PendingDictation].self, from: data) {
            // Drop entries whose audio is gone.
            items = decoded.filter { p in p.parts.allSatisfy { FileManager.default.fileExists(atPath: folder(p.id).appendingPathComponent($0).path) } }
        }
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Moves the recording's audio into permanent storage. Returns nil if there is no audio to keep.
    @discardableResult
    func add(_ rec: Recording, focus: FocusSnapshot, command: Bool, error: String) -> PendingDictation? {
        guard !rec.parts.isEmpty else { return nil }
        var p = PendingDictation(app: focus.appName, bundleID: focus.bundleID, command: command,
                                 contextBefore: focus.textBeforeCursor, selection: focus.selectedText,
                                 duration: rec.duration, peak: rec.peak, parts: [], error: error)
        let dir = folder(p.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in rec.parts {
                try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
                p.parts.append(url.lastPathComponent)
            }
        } catch {
            NSLog("Oneshot: couldn't keep the failed recording: (error)")
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        rec.discard()
        items.insert(p, at: 0)
        while items.count > Self.maxItems { remove(items[items.count - 1].id) }
        save()
        return p
    }

    func recording(for p: PendingDictation) -> Recording {
        Recording(parts: p.parts.map { folder(p.id).appendingPathComponent($0) }, duration: p.duration, peak: p.peak)
    }

    func item(_ id: UUID) -> PendingDictation? { items.first { $0.id == id } }

    func failedAgain(_ id: UUID, error: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].error = error
        items[i].attempts += 1
        save()
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(items) { try? data.write(to: index, options: .atomic) }
    }
}
