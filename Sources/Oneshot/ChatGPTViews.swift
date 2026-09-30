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

/// Settings → Account: connect, status, model, disconnect.
struct ChatGPTPlanCard: View {
    @ObservedObject private var gpt = ChatGPTAccount.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var disconnecting = false
    @State private var revokeNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if gpt.connected {
                connected
            } else {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Use your ChatGPT plan").font(.system(size: 13, weight: .semibold))
                        Text("Cleanup and Command mode run on your ChatGPT Plus or Pro plan instead of Oneshot's servers. Speech-to-text still uses the option above.")
                            .font(.system(size: 11.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    ContinueWithChatGPTButton { gpt.connect() }.disabled(gpt.waiting)
                }
            }
            if gpt.waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish in your browser…").font(.system(size: 12)).foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") { gpt.cancelSignIn() }.buttonStyle(.link).font(.system(size: 12))
                }
                .transition(.opacity)
            }
            if let e = gpt.error {
                Label(e, systemImage: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let revokeNote {
                Text(revokeNote).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Brand.spring, value: gpt.waiting)
        .animation(Brand.spring, value: gpt.connected)
    }

    @ViewBuilder private var connected: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 17)).foregroundColor(.primary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(gpt.email ?? "ChatGPT account").font(.system(size: 13, weight: .semibold))
                    Text("Connected").font(.system(size: 10.5, weight: .semibold)).foregroundColor(Brand.success)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Brand.success.opacity(0.14)))
                }
                Text(gpt.planEnabled ? "ChatGPT plan usage is enabled." : "ChatGPT plan usage isn't enabled for this connection.")
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            Spacer()
            Button(disconnecting ? "Disconnecting…" : "Disconnect") { disconnect() }
                .buttonStyle(SecondaryButtonStyle()).disabled(disconnecting)
        }
        if gpt.planEnabled {
            if gpt.limitReached {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Usage limit reached").font(.system(size: 12, weight: .semibold))
                        Text("Review your plan or this app's limit in ChatGPT settings. Until then, dictations aren't cleaned up.")
                            .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Manage usage") { NSWorkspace.shared.open(SIWC.manageUsage) }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
            }
            Toggle("Use my ChatGPT plan for cleanup and Command mode", isOn: $prefs.useChatGPTPlan)
            if prefs.useChatGPTPlan {
                Picker("Model", selection: $prefs.chatgptModel) {
                    Text("Automatic (\(ChatGPTAccount.pickDefault(gpt.models)?.name ?? "fastest available"))").tag("")
                    ForEach(gpt.models) { m in Text(m.name).tag(m.slug) }
                }
            }
            HStack(spacing: 6) {
                if prefs.useChatGPTPlan {
                    Text("Using ChatGPT plan").font(.system(size: 11.5, weight: .medium)).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                }
                ManageUsageLink()
            }
        } else {
            HStack {
                Text("Allow Oneshot to use your plan to clean up dictations with ChatGPT.").font(.system(size: 11.5)).foregroundColor(.secondary)
                Spacer()
                ContinueWithChatGPTButton(title: "Enable ChatGPT plan", compact: true) { gpt.connect() }
            }
        }
        Button("Use another ChatGPT account") { gpt.connect(anotherAccount: true) }
            .buttonStyle(.link).font(.system(size: 12)).disabled(gpt.waiting)
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

