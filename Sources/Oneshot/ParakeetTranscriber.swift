import Foundation
import FluidAudio

/// On-device transcription with NVIDIA Parakeet TDT v3 (25 languages, Portuguese included) on the
/// Neural Engine, via FluidAudio. The model (~480 MB) downloads once into Application Support.
@MainActor
final class Parakeet: ObservableObject {
    static let shared = Parakeet()

    enum State: Equatable { case missing, downloaded, downloading(Double), loading, ready, failed(String) }
    @Published private(set) var state: State

    private static let modelBytes = 483_000_000.0
    static var modelDir: URL {
        Secrets.dir.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, isDirectory: true)
    }
    static var isDownloaded: Bool { AsrModels.modelsExist(at: modelDir, version: .v3) }

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private var queue: Task<Void, Never>?

    private init() { state = Self.isDownloaded ? .downloaded : .missing }

    var isBusy: Bool {
        switch state {
        case .downloading, .loading: return true
        default: return false
        }
    }

    /// Downloads (first time) and loads the model in the background.
    func warm() { Task { try? await prepare() } }

    func prepare() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { () throws -> AsrManager in
            let dir = Self.modelDir
            if !Self.isDownloaded {
                state = .downloading(0)
                let poll = Task { await self.pollDownload(dir) }
                defer { poll.cancel() }
                try await AsrModels.download(to: dir, version: .v3)
            }
            state = .loading
            let models = try await AsrModels.load(from: dir, version: .v3)
            let m = AsrManager(config: .default)
            try await m.initialize(models: models)
            return m
        }
        loading = task
        do {
            let m = try await task.value
            manager = m
            state = .ready
            loading = nil
            return m
        } catch {
            loading = nil
            let message = Self.describe(error)
            state = .failed(message)
            throw OneshotError.speechUnavailable(message)
        }
    }

    /// Transcribes one file. Fails fast while the model is still downloading, so the recording goes to History.
    func transcribe(url: URL) async throws -> String {
        if manager == nil, !Self.isDownloaded {
            if case .failed(let message) = state { warm(); throw OneshotError.speechUnavailable(message + ". Retrying the download") }
            warm()
            if case .downloading(let p) = state {
                throw OneshotError.speechUnavailable("Parakeet is downloading (\(Int(p * 100))%). Try again when it's done")
            }
            throw OneshotError.speechUnavailable("Parakeet is downloading. Try again when it's done")
        }
        let m = try await prepare()
        let previous = queue
        let job = Task { () throws -> String in
            await previous?.value   // one transcription at a time: the decoder keeps state
            return try await Self.run(m, url)
        }
        queue = Task { _ = await job.result }
        return try await job.value
    }

    func delete() {
        guard !isBusy else { return }
        manager?.cleanup()
        manager = nil
        try? FileManager.default.removeItem(at: Self.modelDir)
        state = .missing
    }

    private nonisolated static func run(_ m: AsrManager, _ url: URL) async throws -> String {
        var texts: [String] = []
        for window in windows(try AudioConverter().resampleAudioFile(url)) where window.count >= 3_200 {
            // Parakeet needs at least 1 s, padded to a whole encoder frame (1280 samples), or it can return nothing.
            var samples = Array(window)
            samples += [Float](repeating: 0, count: (max(samples.count, 16_000) + 1_279) / 1_280 * 1_280 - samples.count)
            let t = try await m.transcribe(samples, source: .system).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { texts.append(t) }
        }
        return texts.joined(separator: " ")
    }

    /// The model sees 15 s at a time and FluidAudio 0.6.1 stitches longer audio with glitches at the seams,
    /// so long audio is cut into ≤14.4 s windows at the quietest 200 ms of each window's last 8 s.
    private nonisolated static func windows(_ s: [Float]) -> [ArraySlice<Float>] {
        let maxLen = 230_400, frame = 3_200, hop = 800
        var out: [ArraySlice<Float>] = []
        var start = 0
        while s.count - start > maxLen {
            var cut = start + maxLen, quietest = Float.infinity
            var i = start + maxLen - 128_000
            while i + frame <= start + maxLen {
                let energy = s[i..<i + frame].reduce(0) { $0 + $1 * $1 }
                if energy < quietest { quietest = energy; cut = i + frame / 2 }
                i += hop
            }
            out.append(s[start..<cut])
            start = cut
        }
        out.append(s[start...])
        return out
    }

    private func pollDownload(_ dir: URL) async {
        while !Task.isCancelled {
            let inFlight = await DownloadUtils.sharedSession.allTasks.reduce(Int64(0)) { $0 + $1.countOfBytesReceived }
            let p = min(0.99, Double(Self.size(of: dir) + inFlight) / Self.modelBytes)
            if case .downloading = state { state = .downloading(p) }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private nonisolated static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            return e.code == .notConnectedToInternet ? "Can't download Parakeet: you're offline" : "Couldn't download Parakeet (network error)"
        }
        return "Parakeet failed: " + String(error.localizedDescription.prefix(80))
    }
}
