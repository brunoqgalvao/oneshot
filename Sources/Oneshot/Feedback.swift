import Foundation
import AppKit
import SwiftUI
import UserNotifications

struct FeedbackItem: Codable, Identifiable, Equatable {
    let id: Int
    let text: String
    let status: String
    let reply: String?
    let createdAt: Double
    let repliedAt: Double?
    let seen: Bool

    var created: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    var statusLabel: String {
        switch status {
        case "working": return "Working on it"
        case "shipped": return "Shipped"
        case "answered": return "Answered"
        case "declined": return "Not planned"
        default: return "Received"
        }
    }
}

/// Feedback goes to the Oneshot server, where an automated loop (Claude Opus)
/// reads it, ships what it can and replies. Replies come back here and are
/// announced with a notification.
@MainActor
final class FeedbackStore: ObservableObject {
    static let shared = FeedbackStore()

    @Published private(set) var items: [FeedbackItem] = []
    @Published private(set) var sending = false
    @Published var error: String?
    var unreadReplies: Int { items.filter { $0.reply != nil && !$0.seen }.count }
    var onOpen: (() -> Void)?

    private var timer: Timer?
    private var notified = Set<Int>()

    /// Random per-install secret; lets this Mac fetch replies to its own feedback.
    static let installID: String = {
        let file = Secrets.dir.appendingPathComponent("install.id")
        if let s = try? String(contentsOf: file, encoding: .utf8), s.count >= 22 { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        let id = Data(b).base64URL
        FileManager.default.createFile(atPath: file.path, contents: Data(id.utf8), attributes: [.posixPermissions: 0o600])
        return id
    }()

    func start() {
        Task { await refresh(notify: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in await FeedbackStore.shared.refresh(notify: true) }
        }
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: Prefs.shared.serverURL.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 20
        r.setValue(Self.installID, forHTTPHeaderField: "X-Install-Id")
        if let token = Account.shared.token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func send(_ text: String) async -> Bool {
        sending = true
        error = nil
        defer { sending = false }
        var r = request("v1/feedback", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let info = Bundle.main.infoDictionary
        let context: [String: Any] = [
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "?",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "engine": Prefs.shared.engine.rawValue,
            "trigger": Prefs.shared.trigger.rawValue,
            "language": Prefs.shared.language,
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "context": context])
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                error = obj?["message"] as? String ?? "Couldn't send feedback. Try again."
                return false
            }
            Self.askForNotifications()
            await refresh(notify: false)
            return true
        } catch {
            self.error = Account.describe(error)
            return false
        }
    }

    func refresh(notify: Bool) async {
        guard let (data, resp) = try? await URLSession.shared.data(for: request("v1/feedback")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode([String: [FeedbackItem]].self, from: data),
              let list = decoded["items"] else { return }
        let fresh = list.filter { $0.reply != nil && !$0.seen && !notified.contains($0.id) }
        items = list
        if notify { for f in fresh { Self.notify(f) } }
        notified.formUnion(fresh.map(\.id))
    }

    /// Called when the user looks at the Feedback page.
    func markSeen() {
        guard unreadReplies > 0 else { return }
        Task {
            _ = try? await URLSession.shared.data(for: request("v1/feedback/seen", method: "POST"))
            await refresh(notify: false)
        }
    }

    static func askForNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func notify(_ f: FeedbackItem) {
        let c = UNMutableNotificationContent()
        c.title = f.status == "shipped" ? "Your feedback shipped 🎉" : "Reply to your feedback"
        c.body = f.reply ?? ""
        c.sound = .default
        c.userInfo = ["feedback": f.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "feedback-\(f.id)", content: c, trigger: nil))
    }
}

struct FeedbackPage: View {
    @ObservedObject private var store = FeedbackStore.shared
    @State private var text = ""
    @State private var sent = false
    @FocusState private var focused: Bool

    var body: some View {
        PageScaffold(title: "Feedback", subtitle: "Bugs, ideas, rants, anything. It goes straight to the builder.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.gradient))
                        Text("An AI engineer (Claude Opus) reads every message, ships what it can, and replies here. You'll get a notification when it does.")
                            .font(.system(size: 12.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $text)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                            .focused($focused)
                            .padding(10)
                        if text.isEmpty {
                            Text("What should Oneshot do better? You can dictate this too.")
                                .font(.system(size: 14)).foregroundColor(.secondary.opacity(0.7))
                                .padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
                        }
                    }
                    .frame(height: 130)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(focused ? Brand.accent.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 1))
                    .animation(Brand.quick, value: focused)

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                if await store.send(text) {
                                    text = ""
                                    withAnimation(Brand.spring) { sent = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation(Brand.spring) { sent = false } }
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if store.sending { ProgressView().controlSize(.small).colorScheme(.dark) }
                                Text("Send feedback")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || store.sending)
                        if sent {
                            Label("Sent. Thank you!", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12.5, weight: .medium)).foregroundColor(Brand.success)
                                .transition(.opacity.combined(with: .offset(x: -6)))
                        }
                        if let err = store.error {
                            Text(err).font(.system(size: 12)).foregroundColor(.red)
                        }
                        Spacer()
                        Text("⌘↩").font(.system(size: 11)).foregroundColor(.secondary)
                    }

                    if !store.items.isEmpty {
                        Text("Your feedback").font(.system(size: 15, weight: .semibold)).padding(.top, 8)
                        VStack(spacing: 10) {
                            ForEach(store.items) { f in FeedbackCard(item: f) }
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 32)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .onAppear {
            Task { await store.refresh(notify: false); store.markSeen() }
        }
    }
}

private struct FeedbackCard: View {
    let item: FeedbackItem
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusChip(status: item.status, label: item.statusLabel)
                Spacer()
                Text(item.created, style: .relative).font(.system(size: 11)).foregroundColor(.secondary) + Text(" ago").font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text(item.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let reply = item.reply {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10)).foregroundColor(Brand.accent).padding(.top, 3)
                    Text(reply).font(.system(size: 12.5)).foregroundColor(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.accent.opacity(0.07)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct StatusChip: View {
    let status: String
    let label: String
    private var color: Color {
        switch status {
        case "shipped": return Brand.success
        case "working": return .orange
        case "answered": return .blue
        case "declined": return .secondary
        default: return .secondary
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}
