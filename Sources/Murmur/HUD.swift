import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening
        case processing
        case done(String)
        case error(String)
        case notice(String)
    }

    static let barCount = 28
    @Published var phase: Phase = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0, count: HUDModel.barCount)
    @Published var locked = false
    @Published var command = false
    @Published var startedAt = Date()
    @Published var hint: String?

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    func push(level: CGFloat) {
        var l = levels
        l.removeFirst()
        // Ease toward the new value so bars feel alive but not jittery.
        let prev = l.last ?? 0
        l.append(prev * 0.25 + level * 0.75)
        levels = l
    }

    func resetLevels() { levels = Array(repeating: 0, count: Self.barCount) }
}

private final class HUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
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
        position()
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { model.phase = phase }
        panel.ignoresMouseEvents = !(phase == .listening && model.locked)
        if let delay = autoHideAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.dismissToken == token else { return }
                self.hide()
            }
        }
    }

    func setLocked(_ locked: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.locked = locked }
        panel.ignoresMouseEvents = !(model.phase == .listening && locked)
    }

    func setCommand(_ on: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.command = on }
    }

    func hide() {
        dismissToken += 1
        let token = dismissToken
        withAnimation(.easeIn(duration: 0.18)) { model.phase = .hidden }
        panel.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.dismissToken == token else { return }
            self.panel.orderOut(nil)
        }
    }

    var isVisible: Bool { model.phase != .hidden }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 6))
    }
}

// MARK: - Views

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if model.phase != .hidden {
                VStack(spacing: 6) {
                    if model.phase == .listening, let hint = model.hint {
                        Text(hint)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .transition(.opacity)
                    }
                    pill
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.5, anchor: .bottom).combined(with: .opacity),
                    removal: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)))
            }
        }
        .frame(width: 460, height: 120, alignment: .bottom)
        .padding(.bottom, 10)
    }

    private var pill: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, model.phase == .listening && model.locked ? 6 : 14)
            .frame(height: 38)
            .background(
                Capsule()
                    .fill(Color(white: 0.07).opacity(0.94))
                    .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
            .fixedSize()
    }

    private var borderColor: Color {
        if model.command && (model.phase == .listening || model.phase == .processing) {
            return Color(red: 0.62, green: 0.5, blue: 1).opacity(0.7)
        }
        return .white.opacity(0.13)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening:
            if model.locked {
                RoundButton(symbol: "xmark", fg: .white.opacity(0.85), bg: .white.opacity(0.14)) { model.onCancel?() }
                    .help("Cancel (Esc)")
            }
            if model.command {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 0.72, green: 0.62, blue: 1))
            } else if !model.locked {
                PulsingDot()
            }
            Waveform(levels: model.levels, tint: model.command ? Color(red: 0.8, green: 0.74, blue: 1) : .white)
            if model.locked {
                ElapsedLabel(since: model.startedAt)
                RoundButton(symbol: "stop.fill", fg: .white, bg: Color(red: 0.95, green: 0.25, blue: 0.3)) { model.onStop?() }
                    .help("Finish")
            }
        case .processing:
            ThinkingBars(tint: model.command ? Color(red: 0.8, green: 0.74, blue: 1) : .white)
            if model.command {
                Text("Rewriting").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.8))
            }
        case .done(let msg):
            Image(systemName: "checkmark.circle.fill").foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                .font(.system(size: 15, weight: .semibold))
            Text(msg).font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.92))
        case .error(let msg):
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 14))
            Text(msg).font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.92)).lineLimit(2)
                .frame(maxWidth: 360)
        case .notice(let msg):
            Image(systemName: "info.circle.fill").foregroundColor(.white.opacity(0.7)).font(.system(size: 14))
            Text(msg).font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.92))
        }
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let tint: Color
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                // Fade the oldest bars so the waveform feels like it scrolls in.
                let fade = 0.35 + 0.65 * Double(i) / Double(max(1, levels.count - 1))
                Capsule()
                    .fill(tint.opacity(fade))
                    .frame(width: 2.5, height: max(3, min(22, 3 + levels[i] * 22)))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

private struct ThinkingBars: View {
    let tint: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<14, id: \.self) { i in
                    let phase = sin(t * 6.5 - Double(i) * 0.45)
                    Capsule()
                        .fill(tint.opacity(0.45 + 0.4 * (phase + 1) / 2))
                        .frame(width: 2.5, height: 4 + 9 * (phase + 1) / 2)
                }
            }
            .frame(height: 24)
        }
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(red: 1, green: 0.27, blue: 0.3))
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { on = true } }
    }
}

private struct ElapsedLabel: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = Int(ctx.date.timeIntervalSince(since))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.75))
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let fg: Color
    let bg: Color
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(fg)
                .frame(width: 26, height: 26)
                .background(Circle().fill(bg).brightness(hover ? 0.08 : 0))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
