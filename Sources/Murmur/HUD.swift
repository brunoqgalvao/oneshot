import AppKit
import SwiftUI

/// Audio levels for the waveform. Kept out of SwiftUI state on purpose: the
/// waveform redraws every display frame and reads this directly, so updates at
/// ~40 Hz never trigger view diffing.
final class LevelMeter {
    static let bars = 25
    private let half = LevelMeter.bars / 2 + 1
    private var history: [CGFloat]
    private(set) var shown: [CGFloat]
    private var lastT: Double = 0

    init() {
        history = Array(repeating: 0, count: half)
        shown = Array(repeating: 0, count: Self.bars)
    }

    func push(_ level: CGFloat) {
        // Noise gate: room tone stays flat, speech moves the bars.
        let gated = level < 0.07 ? 0 : min(1, (level - 0.07) / 0.93)
        history.removeLast()
        history.insert(gated, at: 0)
    }

    func reset() {
        history = Array(repeating: 0, count: half)
    }

    enum Mode { case live, thinking }

    /// Moves displayed heights toward their targets. Called once per frame.
    func advance(to t: Double, mode: Mode) {
        let dt = lastT == 0 ? 1.0 / 60 : min(0.05, max(0.001, t - lastT))
        lastT = t
        let c = Self.bars / 2
        for i in 0..<Self.bars {
            let d = abs(i - c)
            let target: CGFloat
            switch mode {
            case .live:
                // Newest level in the middle, older levels ripple outward.
                let envelope = 1 - CGFloat(d) / CGFloat(c + 3)
                target = history[min(d, history.count - 1)] * envelope
            case .thinking:
                let wave = (sin(t * 5.2 - Double(i) * 0.5) + 1) / 2
                target = 0.12 + 0.3 * CGFloat(wave)
            }
            let rising = target > shown[i]
            let rate: Double = rising ? 28 : 9   // fast attack, slow release
            shown[i] += (target - shown[i]) * CGFloat(1 - exp(-rate * dt))
        }
    }
}

final class HUDModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening
        case processing
        case done(String)
        case error(String)
        case notice(String)

        var isHidden: Bool { self == .hidden }
        var kind: Int {
            switch self {
            case .hidden: return 0
            case .listening: return 1
            case .processing: return 2
            case .done: return 3
            case .error: return 4
            case .notice: return 5
            }
        }
    }

    @Published var phase: Phase = .hidden
    @Published var locked = false
    @Published var command = false
    @Published var canRetry = false
    @Published var startedAt = Date()
    @Published var hint: String?
    let meter = LevelMeter()

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?

    func push(level: CGFloat) { meter.push(level) }
    func resetLevels() { meter.reset() }
}

private final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 132),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The floating pill at the bottom of the screen. Never takes focus, so the
/// text still lands in the app the user was typing in.
final class HUD {
    let model = HUDModel()
    /// Called with true when the HUD appears and false once it's gone.
    var onVisibilityChange: ((Bool) -> Void)?
    private lazy var panel: HUDPanel = {
        let p = HUDPanel()
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = p.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }()
    private var dismissToken = 0

    func show(_ phase: HUDModel.Phase, autoHideAfter: Double? = nil) {
        dismissToken += 1
        let token = dismissToken
        if model.phase.isHidden { position() }
        onVisibilityChange?(true)
        panel.orderFrontRegardless()
        withAnimation(Brand.spring) { model.phase = phase }
        updateMouse()
        if let delay = autoHideAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.dismissToken == token else { return }
                self.hide()
            }
        }
    }

    func setLocked(_ locked: Bool) {
        withAnimation(Brand.spring) { model.locked = locked }
        updateMouse()
    }

    func setCommand(_ on: Bool) {
        withAnimation(Brand.spring) { model.command = on }
    }

    func hide() {
        dismissToken += 1
        let token = dismissToken
        withAnimation(.easeIn(duration: 0.16)) { model.phase = .hidden }
        panel.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.dismissToken == token else { return }
            self.panel.orderOut(nil)
            self.onVisibilityChange?(false)
        }
    }

    var isVisible: Bool { !model.phase.isHidden }

    private func updateMouse() {
        let interactive: Bool
        switch model.phase {
        case .listening: interactive = model.locked
        case .error: interactive = model.canRetry
        default: interactive = false
        }
        panel.ignoresMouseEvents = !interactive
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 4))
    }
}

// MARK: - Views

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.phase == .listening, let hint = model.hint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)).animation(Brand.spring.delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
            if !model.phase.isHidden {
                Pill(model: model)
                    .transition(.asymmetric(
                        insertion: Brand.reduceMotion ? .opacity : .modifier(active: PillEnter(on: false), identity: PillEnter(on: true)),
                        removal: .modifier(active: PillExit(on: true), identity: PillExit(on: false))))
            }
        }
        .frame(width: 520, height: 132, alignment: .bottom)
        .padding(.bottom, 12)
        .environment(\.colorScheme, .dark)
    }
}

private struct PillEnter: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1 : 0.86, anchor: .bottom).opacity(on ? 1 : 0).offset(y: on ? 0 : 10).blur(radius: on ? 0 : 4)
    }
}

private struct PillExit: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 0.97 : 1, anchor: .bottom).opacity(on ? 0 : 1).offset(y: on ? 6 : 0)
    }
}

struct Pill: View {
    @ObservedObject var model: HUDModel

    private var showsWave: Bool { model.phase == .listening || model.phase == .processing }
    private var tint: Color { model.command ? Brand.commandTint : .white }
    private var layoutKey: String { "\(model.phase.kind)-\(model.locked)-\(model.command)-\(model.canRetry)" }

    var body: some View {
        HStack(spacing: 10) {
            leading
            if showsWave {
                LiveWaveform(meter: model.meter, mode: model.phase == .processing ? .thinking : .live, tint: tint)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            trailing
        }
        .padding(.leading, leadingPad)
        .padding(.trailing, trailingPad)
        .frame(height: 40)
        .background(PillBackground(command: model.command && showsWave))
        .fixedSize()
        .animation(Brand.spring, value: layoutKey)
    }

    private var leadingPad: CGFloat { model.phase == .listening && model.locked ? 6 : 14 }
    private var trailingPad: CGFloat {
        if model.phase == .listening && model.locked { return 6 }
        if case .error = model.phase, model.canRetry { return 6 }
        return 16
    }

    @ViewBuilder private var leading: some View {
        switch model.phase {
        case .listening:
            if model.locked {
                HUDButton(symbol: "xmark", fg: .white.opacity(0.9), bg: .white.opacity(0.14), help: "Cancel (esc)") { model.onCancel?() }
                    .transition(.iconSwap)
            } else if model.command {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.commandTint)
                    .transition(.iconSwap)
            } else {
                RecordingDot().transition(.iconSwap)
            }
        case .processing:
            if model.command {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundColor(Brand.commandTint)
                    .transition(.iconSwap)
            }
        case .done:
            DrawnCheck(size: 18).transition(.iconSwap)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundColor(.orange)
                .transition(.iconSwap)
        case .notice:
            Image(systemName: "info.circle.fill").font(.system(size: 14)).foregroundColor(.white.opacity(0.75))
                .transition(.iconSwap)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .listening where model.locked:
            ElapsedLabel(since: model.startedAt).transition(.opacity)
            HUDButton(symbol: "stop.fill", fg: .white, bg: Brand.recordRed, help: "Finish (\(Prefs.shared.trigger.short))") { model.onStop?() }
                .transition(.iconSwap)
        case .processing where model.command:
            Text("Rewriting").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.8)).transition(.opacity)
        case .done(let msg), .notice(let msg):
            Text(msg).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.94))
                .transition(.opacity)
        case .error(let msg):
            Text(msg).font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.94))
                .lineLimit(2).frame(maxWidth: 330, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            if model.canRetry {
                Button { model.onRetry?() } label: {
                    Text("Retry").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                        .contentShape(Capsule().inset(by: -6))
                }
                .buttonStyle(PressableStyle())
                .transition(.iconSwap)
            }
        default:
            EmptyView()
        }
    }
}

private struct PillBackground: View {
    let command: Bool
    var body: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color(white: 0.05).opacity(0.82))
            // Lit top edge instead of a flat border.
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
            if command {
                Capsule().strokeBorder(Brand.violet.opacity(0.75), lineWidth: 1.2)
                    .shadow(color: Brand.violet.opacity(0.6), radius: 8)
                    .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
    }
}

struct LiveWaveform: View {
    let meter: LevelMeter
    let mode: LevelMeter.Mode
    let tint: Color
    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 2.6

    var body: some View {
        let n = LevelMeter.bars
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                meter.advance(to: ctx.date.timeIntervalSinceReferenceDate, mode: mode)
                let c = CGFloat(n - 1) / 2
                for i in 0..<n {
                    let h = max(barWidth, min(size.height, barWidth + meter.shown[i] * (size.height - barWidth)))
                    let x = CGFloat(i) * (barWidth + gap)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    let edge = 1 - pow(abs(CGFloat(i) - c) / c, 2) * 0.55
                    g.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint.opacity(Double(edge))))
                }
            }
        }
        .frame(width: CGFloat(n) * (barWidth + gap) - gap, height: 22)
    }
}

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(Brand.recordRed.opacity(0.35)).frame(width: 14, height: 14).scaleEffect(on ? 1 : 0.5).opacity(on ? 0 : 1)
            Circle().fill(Brand.recordRed).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard !Brand.reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

private struct ElapsedLabel: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.72))
        }
    }
}

private struct HUDButton: View {
    let symbol: String
    let fg: Color
    let bg: Color
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(fg)
                .frame(width: 28, height: 28)
                .background(Circle().fill(bg).brightness(hover ? 0.08 : 0))
                .contentShape(Circle().inset(by: -6))  // ~40pt hit area
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(Brand.quick) { hover = h } }
        .help(help)
    }
}
