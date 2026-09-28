import AVFoundation

enum MurmurError: LocalizedError {
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

struct Recording {
    let samples: [Float]      // 16 kHz mono
    let sampleRate: Double = 16_000
    let peak: Float
    var duration: Double { Double(samples.count) / sampleRate }

    /// Encodes to AAC (m4a, ~3 KB/s) so uploads stay small on slow connections.
    /// Falls back to 16-bit WAV if the AAC encoder is unavailable.
    func writeCompressed() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let m4a = dir.appendingPathComponent("\(id).m4a")
        do {
            try write(to: m4a, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            ])
            return m4a
        } catch {
            let wav = dir.appendingPathComponent("\(id).wav")
            try write(to: wav, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ])
            return wav
        }
    }

    private func write(to url: URL, settings: [String: Any]) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw MurmurError.noMicrophone
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
    }

    /// Loads any audio file as a Recording (used for testing and retries).
    static func load(url: URL) throws -> Recording {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw MurmurError.badResponse }
        try file.read(into: input)
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { throw MurmurError.badResponse }
        let cap = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate + 1024)
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)!
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        let n = Int(out.frameLength)
        let arr = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
        return Recording(samples: arr, peak: arr.reduce(0) { max($0, abs($1)) })
    }
}

/// Captures the default input device, converting to 16 kHz mono on the fly and
/// reporting a 0...1 level for the waveform.
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private var peak: Float = 0
    private let lock = NSLock()
    private(set) var isRunning = false

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start() throws {
        guard Self.permission != .denied, Self.permission != .restricted else { throw MurmurError.microphoneDenied }
        lock.lock(); samples.removeAll(keepingCapacity: true); samples.reserveCapacity(16_000 * 30); peak = 0; lock.unlock()

        // A fresh engine picks up device changes (AirPods connecting, etc.).
        engine = AVAudioEngine()
        let input = engine.inputNode
        let uid = Prefs.shared.inputDeviceUID
        if !uid.isEmpty, let unit = input.audioUnit { AudioDevices.select(uid: uid, on: unit) }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MurmurError.noMicrophone }
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
        return Recording(samples: samples, peak: peak)
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
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        peak = max(peak, pk)
        lock.unlock()
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        onLevel?(max(0, min(1, (db + 55) / 42)))
    }
}
