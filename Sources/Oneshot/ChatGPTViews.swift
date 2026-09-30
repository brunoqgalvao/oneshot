import SwiftUI
import AppKit

// MARK: - Sign in with ChatGPT UI (follows developers.openai.com/siwc/ui-ux-guidelines)

/// The approved "Continue with ChatGPT" button: black, white ChatGPT logo.
struct ContinueWithChatGPTButton: View {
    var title = "Continue with ChatGPT"
    var compact = false
    let action: () -> Void
    @State private var hover = false
    private static let logo: NSImage? = Bundle.main.url(forResource: "chatgpt-logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let logo = Self.logo { Image(nsImage: logo).resizable().interpolation(.high).frame(width: 16, height: 16) }
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            }
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? 30 : 34)
            .background(Capsule().fill(Color.black.opacity(hover ? 0.82 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

struct ManageUsageLink: View {
    var body: some View {
        Button("Manage usage") { NSWorkspace.shared.open(SIWC.manageUsage) }
            .buttonStyle(.link)
            .font(.system(size: 12))
    }
}

/// Settings → Account: ChatGPT as one row of the accounts list. It works alongside the
/// transcription choice above it, so it gets a switch instead of a radio button.
struct ChatGPTAccountRow: View {
    @ObservedObject private var gpt = ChatGPTAccount.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var disconnecting = false
    @State private var revokeNote: String?
    @State private var hover = false
    private static let logo: NSImage? = Bundle.main.url(forResource: "chatgpt-logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    private var active: Bool { gpt.connected && gpt.planEnabled && prefs.useChatGPTPlan }

    private var detail: String {
        guard gpt.connected else { return "Clean up and rewrite on your ChatGPT Plus or Pro plan." }
        let who = gpt.email ?? "Connected"
        if !gpt.planEnabled { return who + " · plan usage isn't enabled" }
        return prefs.useChatGPTPlan ? who : who + " · off, Oneshot cleans up"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(active || !gpt.connected ? 1 : 0.45))
                    if let logo = Self.logo { Image(nsImage: logo).resizable().interpolation(.high).frame(width: 16, height: 16) }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("ChatGPT").font(.system(size: 13, weight: .semibold))
                        if gpt.connected {
                            Text("Connected").font(.system(size: 10.5, weight: .semibold)).foregroundColor(Brand.success)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(Brand.success.opacity(0.14)))
                        }
                    }
                    Text(detail).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(10)

            if active {
                HStack(spacing: 6) {
                    Text("Model").font(.system(size: 12)).foregroundColor(.secondary)
                    Picker("Model", selection: $prefs.chatgptModel) {
                        Text("Automatic (\(ChatGPTAccount.pickDefault(gpt.models)?.name ?? "fastest available"))").tag("")
                        ForEach(gpt.models) { m in Text(m.name).tag(m.slug) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    Spacer(minLength: 8)
                    ManageUsageLink().fixedSize()
                }
                .padding(.leading, 52).padding(.trailing, 10).padding(.bottom, 10)
                .transition(.opacity)
            }
            if active && gpt.limitReached {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Usage limit reached. Until it resets, dictations aren't cleaned up.")
                        .font(.system(size: 11.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 52).padding(.trailing, 10).padding(.bottom, 10)
            }
            notes.padding(.leading, 52).padding(.trailing, 10)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(active ? 0.05 : (hover ? 0.03 : 0))))
        .onHover { hover = $0 }
        .animation(Brand.spring, value: active)
        .animation(Brand.spring, value: gpt.waiting)
        .animation(Brand.spring, value: gpt.connected)
    }

    @ViewBuilder private var trailing: some View {
        if !gpt.connected {
            ContinueWithChatGPTButton(compact: true) { gpt.connect() }.disabled(gpt.waiting)
        } else {
            HStack(spacing: 4) {
                if gpt.planEnabled {
                    Toggle("Use my ChatGPT plan", isOn: $prefs.useChatGPTPlan)
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .help("Use my ChatGPT plan for cleanup and Command mode")
                } else {
                    Button("Enable plan") { gpt.connect() }.buttonStyle(SecondaryButtonStyle())
                }
                Menu {
                    Button("Manage usage") { NSWorkspace.shared.open(SIWC.manageUsage) }
                    Button("Use another ChatGPT account") { gpt.connect(anotherAccount: true) }
                    Divider()
                    Button(disconnecting ? "Disconnecting…" : "Disconnect") { disconnect() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(disconnecting || gpt.waiting)
            }
        }
    }

    @ViewBuilder private var notes: some View {
        if gpt.waiting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finish in your browser…").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { gpt.cancelSignIn() }.buttonStyle(.link).font(.system(size: 12))
            }
            .padding(.bottom, 10)
            .transition(.opacity)
        }
        if let e = gpt.error {
            Label(e, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
        }
        if let revokeNote {
            Text(revokeNote).font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
        }
    }

    private func disconnect() {
        disconnecting = true
        Task { @MainActor in
            let revoked = await gpt.disconnect()
            revokeNote = revoked ? nil : "Signed out on this Mac, but ChatGPT didn't confirm it. You can also disconnect Oneshot in ChatGPT settings."
            disconnecting = false
        }
    }
}


/// Home: invites signed-in people to use their ChatGPT plan. Dismissible, shown until they connect.
struct ChatGPTInviteBanner: View {
    @ObservedObject private var gpt = ChatGPTAccount.shared
    @AppStorage("chatgptInviteDismissed") private var dismissed = false

    var body: some View {
        if !gpt.connected && !dismissed {
            HStack(spacing: 12) {
                Text("New").font(.system(size: 10.5, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use your ChatGPT plan in Oneshot.").font(.system(size: 13, weight: .semibold))
                    Text("Plus and Pro members can run cleanup and Command mode on their plan.").font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                ContinueWithChatGPTButton(compact: true) { gpt.connect() }.disabled(gpt.waiting)
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .help("Hide")
            }
            .padding(12)
            .surface(radius: 14)
        }
    }
}

/// Home: a small "Using ChatGPT plan · Manage usage" line while the plan powers requests.
struct UsingChatGPTPlanLine: View {
    @ObservedObject private var gpt = ChatGPTAccount.shared
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        if gpt.connected && gpt.planEnabled && prefs.useChatGPTPlan {
            HStack(spacing: 6) {
                Image(systemName: gpt.limitReached ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(gpt.limitReached ? .orange : Brand.success).font(.system(size: 11))
                Text(gpt.limitReached ? "ChatGPT usage limit reached" : "Using ChatGPT plan").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                Text("·").foregroundColor(.secondary)
                ManageUsageLink()
            }
        }
    }
}
