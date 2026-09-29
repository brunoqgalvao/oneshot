import SwiftUI
import AppKit

// MARK: - Design tokens

enum Brand {
    /// Oneshot orange: the "shot". Deep enough for white text on buttons.
    static let accent = Color(red: 0.93, green: 0.30, blue: 0.16)
    static let accentDeep = Color(red: 0.78, green: 0.18, blue: 0.10)
    static let commandTint = Color(red: 0.78, green: 0.72, blue: 1)
    static let recordRed = Color(red: 1, green: 0.29, blue: 0.33)
    static let success = Color(red: 0.25, green: 0.82, blue: 0.47)
    static var gradient: LinearGradient {
        LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.24), accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Critically damped springs (no bounce), interruptible.
    static let spring = Animation.spring(response: 0.34, dampingFraction: 1)
    static let quick = Animation.spring(response: 0.22, dampingFraction: 1)
    /// Strong ease-out (Craft: cubic-bezier(0.23, 1, 0.32, 1)) for anything the user triggers.
    static func easeOut(_ duration: Double) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }
    /// Button press: short, transform only.
    static let press = easeOut(0.1)
    /// Title tracking for display sizes (about -0.02em).
    static func tracking(_ size: CGFloat) -> CGFloat { -0.02 * size }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

// MARK: - Surfaces

/// Card surface: the edge is a layered shadow ring, not a border, so stacked surfaces never pile up lines.
struct Surface: ViewModifier {
    var radius: CGFloat = 14
    var fill: Color = Color(nsColor: .controlBackgroundColor)
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        return content
            .background(
                shape.fill(fill)
                    .shadow(color: .black.opacity(dark ? 0.1 : 0.06), radius: 1, y: 1)   // contact
                    .shadow(color: .black.opacity(dark ? 0.1 : 0.04), radius: 4, y: 2)   // ambient
            )
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06), lineWidth: 1)) // ring
    }
}

extension View {
    func surface(radius: CGFloat = 14, fill: Color = Color(nsColor: .controlBackgroundColor)) -> some View {
        modifier(Surface(radius: radius, fill: fill))
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Brand.accent
    var fullWidth = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(enabled ? 1 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: tint.opacity(enabled ? 0.28 : 0), radius: configuration.isPressed ? 2 : 6, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed && enabled ? 0.97 : 1)
            .animation(Brand.press, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : 0.06)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Brand.press, value: configuration.isPressed)
            .onHover { hover = $0 }   // hover highlights switch instantly
            .contentShape(Rectangle())
    }
}

/// Plain button that only adds the tactile press scale.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Brand.press, value: configuration.isPressed)
    }
}

// MARK: - Key caps

struct KeyCap: View {
    let label: String
    var pressed = false
    var large = false

    var body: some View {
        let r: CGFloat = large ? 12 : 6
        Text(label)
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: large ? 26 : 12, weight: .medium, design: .rounded))
            .foregroundColor(pressed ? .white : .primary.opacity(0.85))
            .padding(.horizontal, large ? 22 : 7)
            .frame(minWidth: large ? 88 : 26, minHeight: large ? 76 : 24)
            .background(
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .fill(pressed ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
            )
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(Color.primary.opacity(pressed ? 0 : 0.12), lineWidth: 1))
            // The key's "side": a hard shadow that flattens when pressed.
            .shadow(color: .black.opacity(pressed ? 0 : 0.14), radius: 0, x: 0, y: large ? 3 : 1.5)
            .shadow(color: Brand.accent.opacity(pressed ? 0.45 : 0), radius: large ? 18 : 6)
            .offset(y: pressed ? (large ? 3 : 1) : 0)
            .animation(Brand.quick, value: pressed)
    }
}

/// "Hold fn — Dictate" style reference rows.
struct ShortcutList: View {
    let trigger: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row([trigger], prefix: "Hold", "Dictate, release to insert")
            row([trigger, trigger], prefix: "Double-tap", "Hands-free, tap again to finish")
            row([trigger, "Space"], prefix: nil, "Switch to hands-free while holding")
            row(["⌃"], prefix: "Hold", "While dictating: Command mode, to rewrite a selection")
            row(["esc"], prefix: nil, "Cancel")
        }
    }

    private func row(_ keys: [String], prefix: String?, _ text: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                if let prefix { Text(prefix).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary) }
                ForEach(Array(keys.enumerated()), id: \.offset) { _, k in KeyCap(label: k) }
            }
            .frame(width: 150, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }
}

// MARK: - Motion helpers

/// Staggered entrance: fade and a short rise, 40ms apart, so the last item starts within ~200ms.
struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Brand.reduceMotion ? 0 : 8)
            .onAppear {
                withAnimation(Brand.easeOut(0.36).delay(0.03 + Double(index) * 0.04)) { shown = true }
            }
    }
}

extension View {
    func staggerIn(_ index: Int) -> some View { modifier(StaggerIn(index: index)) }
}

/// Icon swap: scale 0.25→1, opacity 0→1, blur 4→0.
struct IconSwap: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.25 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 4 : 0)
    }
}

extension AnyTransition {
    static var iconSwap: AnyTransition { .modifier(active: IconSwap(active: true), identity: IconSwap(active: false)) }
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// A checkmark that draws itself.
struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.2, y: r.midY + r.height * 0.02))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.maxY - r.height * 0.24))
        p.addLine(to: CGPoint(x: r.maxX - r.width * 0.18, y: r.minY + r.height * 0.26))
        return p
    }
}

struct DrawnCheck: View {
    var size: CGFloat = 18
    var color: Color = Brand.success
    @State private var progress: CGFloat = 0
    var body: some View {
        ZStack {
            Circle().fill(color)
            CheckShape()
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round, lineJoin: .round))
                .padding(size * 0.16)
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 0.32).delay(0.08)) { progress = 1 } }
    }
}

// MARK: - Status

struct StatusDot: View {
    let ok: Bool
    var optional = false
    var body: some View {
        ZStack {
            if ok {
                DrawnCheck(size: 18).transition(.iconSwap)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: optional ? [2.5, 2.5] : []))
                    .frame(width: 18, height: 18)
                    .transition(.iconSwap)
            }
        }
        .animation(Brand.spring, value: ok)
        .frame(width: 20)
    }
}

struct UsageBar: View {
    let usage: CloudUsage
    var body: some View {
        let frac = min(1, max(0, usage.usedSeconds / max(1, usage.limitSeconds)))
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    // Nothing used yet means an empty track, not a stray dot.
                    if frac > 0 {
                        Capsule().fill(frac > 0.9 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Brand.gradient))
                            .frame(width: max(6, g.size.width * frac))
                    }
                }
            }
            .frame(height: 6)
            Text("\(usage.remainingMinutes) of \(usage.limitMinutes) free minutes left today")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}

/// Rounded tile with a gradient and an SF Symbol, used as step art.
struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 76
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Brand.gradient))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: Brand.accent.opacity(0.35), radius: 14, y: 6)
    }
}

// MARK: - Account form (onboarding + settings)

struct AccountForm: View {
    @ObservedObject private var account = Account.shared
    var onSuccess: (() -> Void)? = nil
    @State private var create = true
    @State private var email = ""
    @State private var password = ""
    @State private var reveal = false
    @State private var shakes: CGFloat = 0
    @FocusState private var focus: Field?
    enum Field { case email, password }

    private var valid: Bool { email.contains("@") && email.contains(".") && password.count >= 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GoogleButton(waiting: account.waitingForGoogle) { account.signInWithGoogle() }
            if account.waitingForGoogle {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") { account.cancelGoogle() }.buttonStyle(.link).font(.system(size: 12))
                }
                .transition(.opacity)
            }
            HStack(spacing: 10) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                Text("or use email").font(.system(size: 11)).foregroundColor(.secondary).fixedSize()
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            }
            .padding(.vertical, 2)
            Picker("", selection: $create) {
                Text("Create account").tag(true)
                Text("Sign in").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .textContentType(.username)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
            HStack(spacing: 6) {
                Group {
                    if reveal { TextField(create ? "Password (8+ characters)" : "Password", text: $password) }
                    else { SecureField(create ? "Password (8+ characters)" : "Password", text: $password) }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($focus, equals: .password)
                .onSubmit(submit)
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .foregroundColor(.secondary)
                .help(reveal ? "Hide password" : "Show password")
            }
            HStack(spacing: 10) {
                Button(action: submit) {
                    HStack(spacing: 8) {
                        if account.busy { ProgressView().controlSize(.small).colorScheme(.dark) }
                        Text(create ? "Create free account" : "Sign in")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!valid || account.busy)
            }
            .modifier(Shake(animatableData: shakes))
            if let err = account.error {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if create {
                Text("Free: \(30) minutes of dictation a day. No API key needed.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .animation(Brand.spring, value: account.error)
        .animation(Brand.spring, value: account.waitingForGoogle)
        .onChange(of: create) { _ in account.error = nil }
        .onAppear { if !account.waitingForGoogle { focus = nil } }
    }

    private func submit() {
        guard valid, !account.busy else { return }
        Task {
            await account.signIn(create: create, email: email, password: password)
            if account.isSignedIn {
                password = ""
                onSuccess?()
            } else {
                withAnimation(.linear(duration: 0.4)) { shakes += 1 }
            }
        }
    }
}

/// "Continue with Google", following Google's button guidelines (white, logo, neutral border).
struct GoogleButton: View {
    let waiting: Bool
    let action: () -> Void
    @State private var hover = false
    private static let logo: NSImage? = Bundle.main.url(forResource: "google-g", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let logo = Self.logo {
                    Image(nsImage: logo).resizable().interpolation(.high).frame(width: 18, height: 18)
                } else {
                    Text("G").font(.system(size: 15, weight: .bold)).foregroundColor(.blue)
                }
                Text("Continue with Google").font(.system(size: 13.5, weight: .medium)).foregroundColor(Color(red: 0.12, green: 0.12, blue: 0.12))
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.92 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(red: 0.45, green: 0.47, blue: 0.46).opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(waiting)
        .opacity(waiting ? 0.6 : 1)
        .onHover { hover = $0 }
    }
}

/// Signed-in account summary.
struct AccountCard: View {
    @ObservedObject private var account = Account.shared
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String((account.email ?? "?").prefix(1)).uppercased())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Brand.gradient))
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.email ?? "Signed in").font(.system(size: 13, weight: .semibold))
                    Text("Free plan").font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let u = account.usage { UsageBar(usage: u).frame(maxWidth: 280) }
            }
            Spacer()
            Button("Sign out") { Task { await account.signOut() } }.buttonStyle(SecondaryButtonStyle())
        }
    }
}

// MARK: - Background

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
