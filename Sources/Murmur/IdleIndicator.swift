import AppKit
import SwiftUI
import ApplicationServices

/// A small always-on pill at the bottom of the screen that says "Murmur is running".
/// Hover to see how to use it, click to start hands-free dictation, right-click for
/// a menu. It hides while the dictation HUD is showing, which takes its place.
@MainActor
final class IdleIndicator {
    final class Model: ObservableObject {
        @Published var hover = false
        @Published var needsSetup = false
        @Published var visible = true
        @Published var trigger = "fn"
    }

    let model = Model()
    var onClick: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSettings: (() -> Void)?

    private var panel: NSPanel?
    private var timer: Timer?
    private var suppressed = false
    private var screenID: CGDirectDisplayID?

    func install() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 46),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = IdleView(model: model,
                            click: { [weak self] in self?.onClick?() },
                            open: { [weak self] in self?.onOpen?() },
                            settings: { [weak self] in self?.onSettings?() },
                            hide: { Prefs.shared.showIndicator = false })
        let host = NSHostingView(rootView: view)
        host.frame = p.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The HUD is showing: step aside.
    func setSuppressed(_ s: Bool) {
        guard s != suppressed else { return }
        suppressed = s
        refresh()
    }

    func refresh() {
        guard let panel else { return }
        let prefs = Prefs.shared
        let controller = AppController.shared
        model.trigger = prefs.trigger.short
        model.needsSetup = !controller.hotkeyActive || AudioRecorder.permission != .authorized
            || (prefs.engine == .cloud && !Account.shared.isSignedIn)
            || (prefs.engine == .openAI && prefs.effectiveAPIKey == nil)
        let show = prefs.showIndicator && !suppressed
        if show != model.visible { withAnimation(Brand.spring) { model.visible = show } }
        position(panel)
        if prefs.showIndicator { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.minY + 2)
        if id != screenID || panel.frame.origin != origin {
            screenID = id
            panel.setFrameOrigin(origin)
        }
    }
}

private struct IdleView: View {
    @ObservedObject var model: IdleIndicator.Model
    let click: () -> Void
    let open: () -> Void
    let settings: () -> Void
    let hide: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.visible {
                pill
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)).animation(Brand.spring.delay(0.35)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
        }
        .frame(width: 280, height: 46, alignment: .bottom)
        .padding(.bottom, 6)
        .environment(\.colorScheme, .dark)
    }

    private var pill: some View {
        HStack(spacing: 7) {
            if model.hover {
                Image(systemName: model.needsSetup ? "exclamationmark.circle.fill" : "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(model.needsSetup ? .orange : .white.opacity(0.9))
                    .transition(.iconSwap)
                Text(model.needsSetup ? "Murmur needs setup · click" : "Hold \(model.trigger) to talk · click to start")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .fixedSize()
                    .transition(.opacity)
            } else if model.needsSetup {
                Circle().fill(Color.orange).frame(width: 5, height: 5).transition(.opacity)
            }
        }
        .padding(.horizontal, model.hover ? 12 : 0)
        .frame(width: model.hover ? nil : 38, height: model.hover ? 28 : 9)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color(white: 0.06).opacity(model.hover ? 0.85 : 0.7)))
        )
        .overlay(Capsule().strokeBorder(
            LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        // An almost-invisible halo makes the tiny pill easy to hover and click.
        .padding(8)
        .background(Capsule().fill(Color.black.opacity(0.012)))
        .contentShape(Capsule())
        .onHover { h in withAnimation(Brand.spring) { model.hover = h } }
        .onTapGesture(perform: click)
        .contextMenu {
            Button("Start dictation", action: click)
            Button("Open Murmur", action: open)
            Button("Settings…", action: settings)
            Divider()
            Button("Hide this indicator", action: hide)
        }
        .help(model.needsSetup ? "Murmur needs setup" : "Murmur is running")
    }
}
