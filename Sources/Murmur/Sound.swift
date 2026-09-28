import AppKit

enum Sound {
    case start, stop, error

    private static var cache: [String: NSSound] = [:]

    static func play(_ s: Sound) {
        guard Prefs.shared.sounds else { return }
        let (name, volume): (String, Float) = {
            switch s {
            case .start: return ("Tink", 0.25)
            case .stop: return ("Pop", 0.2)
            case .error: return ("Funk", 0.2)
            }
        }()
        let sound = cache[name] ?? NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        guard let sound else { return }
        cache[name] = sound
        sound.stop()
        sound.volume = volume
        sound.play()
    }
}
