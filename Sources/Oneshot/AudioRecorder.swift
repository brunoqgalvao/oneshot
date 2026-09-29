import AVFoundation

enum OneshotError: LocalizedError {
    case noMicrophone
    case microphoneDenied
    case noAPIKey
    case http(Int, String)
    case badResponse
    case speechUnavailable(String)
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone found"
        case .microphoneDenied: return "Microphone access is off"
        case .noAPIKey: return "Add an OpenAI API key in Settings"
        case .http(let code, let msg): return "OpenAI \(code): \(msg)"
        case .badResponse: return "Unexpected response from OpenAI"
        case .speechUnavailable(let why): return why
        case .noSpeech: return "Didn't catch that"
        }
    }
}

/// A finished recording: compressed audio on disk, split into parts of up to 5 minutes
/// so a 3-hour dictation never sits in memory and each part fits OpenAI's upload limits.
struct Recording {
    static let maxDuration: Double = 3 * 3600
    var parts: [URL]
    var duration: Double
    var peak: Float
    /// The folder holding the parts (deleted after a successful dictation).
    var folder: URL? { parts.first?.deletingLastPathComponent() }

    func discard() { if let folder { try? FileManager.default.removeItem(at: folder) } }

    /// Loads any audio file as a Recording (used for testing without a microphone).
    static func load(url: URL) throws -> Recording {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw OneshotError.badResponse }
        try file.read(into: input)
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { throw OneshotError.badResponse }
        let cap = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate + 1024)
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        let n = Int(out.frameLength)
        var peak: Float = 0
        if let ch = out.floatChannelData?[0] { for i in 0..<n { peak = max(peak, abs(ch[i])) } }
        let writer = try SegmentWriter()
        // Feed it in microphone-sized buffers so parts split at pauses, like a live recording.
        var offset = 0
        while offset < n, let src = out.floatChannelData?[0] {
            let count = min(4096, n - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)), let dst = slice.floatChannelData?[0] else { break }
            slice.frameLength = AVAudioFrameCount(count)
            dst.update(from: src.advanced(by: offset), count: count)
            try writer.append(slice)
            offset += count
        }
        return Recording(parts: writer.finish(), duration: Double(n) / 16_000, peak: peak)
    }
}

/// Streams 16 kHz mono audio to AAC files (m4a, ~3 KB/s), starting a new file every 5 minutes.
/// Falls back to 16-bit WAV if the AAC encoder is unavailable.
final class SegmentWriter {
    static let partSeconds: Double = 300   // gpt-4o-transcribe truncates its answer on ~8+ minutes of fast speech
    let folder: URL
    private(set) var parts: [URL] = []
    private(set) var totalFrames: Int64 = 0
    private var file: AVAudioFile?
    private var framesInPart: Int64 = 0
    private var useWAV = false

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oneshot", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        let soft = Int64(Self.partSeconds * 16_000)
        let capacity = soft + 30 * 16_000   // hard cut 30 s later if nobody pauses
        // Past the 5-minute mark, start the next part at the first quiet buffer, so words aren't cut in half.
        if file != nil, framesInPart >= soft, framesInPart < capacity, Self.isQuiet(buffer) { try startPart() }
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            if file == nil || framesInPart >= capacity { try startPart() }
            let count = min(buffer.frameLength - offset, AVAudioFrameCount(capacity - framesInPart))
            if offset == 0 && count == buffer.frameLength {
                try file?.write(from: buffer)
            } else {
                // The buffer crosses a part boundary: write it in two slices.
                guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
                      let src = buffer.floatChannelData?[0], let dst = slice.floatChannelData?[0] else { return }
                slice.frameLength = count
                dst.update(from: src.advanced(by: Int(offset)), count: Int(count))
                try file?.write(from: slice)
            }
            offset += count
            framesInPart += Int64(count)
            totalFrames += Int64(count)
        }
    }

    private static func isQuiet(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return false }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        return sqrt(sum / Float(buffer.frameLength)) < 0.01   // about -40 dBFS
    }

    /// Closes the current file and returns every part in order.
    func finish() -> [URL] {
        file = nil   // releasing the AVAudioFile finalizes it
        return parts
    }

    private func startPart() throws {
        file = nil
        framesInPart = 0
        let name = String(format: "part-%03d", parts.count + 1)
        if !useWAV {
            let url = folder.appendingPathComponent(name + ".m4a")
            do {
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 24_000,
                    AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                parts.append(url)
                return
            } catch {
                useWAV = true
            }
        }
        let url = folder.appendingPathComponent(name + ".wav")
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        parts.append(url)
    }
}

/// Captures the default input device, converting to 16 kHz mono on the fly and
/// reporting a 0...1 level for the waveform.
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var writer: SegmentWriter?
    private var peak: Float = 0
    private let lock = NSLock()
    private(set) var isRunning = false

    /// Seconds recorded so far.
    var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(writer?.totalFrames ?? 0) / 16_000
    }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start() throws {
        guard Self.permission != .denied, Self.permission != .restricted else { throw OneshotError.microphoneDenied }
        let w = try SegmentWriter()
        lock.lock(); writer = w; peak = 0; lock.unlock()

        // A fresh engine picks up device changes (AirPods connecting, etc.).
        engine = AVAudioEngine()
        let input = engine.inputNode
        let uid = Prefs.shared.inputDeviceUID
        if !uid.isEmpty, let unit = input.audioUnit { AudioDevices.select(uid: uid, on: unit) }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw OneshotError.noMicrophone }
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() -> Recording {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        lock.lock(); defer { lock.unlock() }
        guard let w = writer else { return Recording(parts: [], duration: 0, peak: 0) }
        writer = nil
        return Recording(parts: w.finish(), duration: Double(w.totalFrames) / 16_000, peak: peak)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        var pk: Float = 0
        for i in 0..<n { let v = ch[i]; sum += v * v; pk = max(pk, abs(v)) }
        lock.lock()
        do { try writer?.append(out) } catch { NSLog("Oneshot: couldn't write audio: \(error)") }
        peak = max(peak, pk)
        lock.unlock()
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        onLevel?(max(0, min(1, (db + 55) / 42)))
    }
}
