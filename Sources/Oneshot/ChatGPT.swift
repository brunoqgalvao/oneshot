import AppKit
import CryptoKit
import Foundation
import Network
import Security

// Sign in with ChatGPT for open-source apps (https://developers.openai.com/siwc/token-sharing-open-source).
// The user authorizes Oneshot in the browser; the app gets tokens that let eligible Plus and Pro users run
// text requests (cleanup and Command mode) on their own ChatGPT plan through the Responses API.
// Speech-to-text isn't part of this flow, so transcription still comes from the chosen engine.

enum SIWC {
    static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let revoke = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    static let jwks = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let api = URL(string: "https://api.openai.com/v1")!
    static let manageUsage = URL(string: "https://chatgpt.com/settings/usage")!
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let planScope = "chatgpt.tokens.use.direct"
    static let dynamicClient = "dynamic_agent_client"
    static let appName = "Oneshot"
}

// MARK: - Errors

enum ChatGPTError: LocalizedError {
    case cancelled, declined, timedOut, stateMismatch, registrationIncomplete, clientMismatch, accountMismatch
    case oauth(String)
    case badIDToken(String)
    case notConnected, planNotEnabled, needsSignIn
    case usageLimit, notEligible, unavailable
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .declined: return "ChatGPT access wasn't allowed"
        case .timedOut: return "Sign-in timed out. Try again."
        case .stateMismatch: return "That sign-in didn't match. Try again."
        case .registrationIncomplete: return "ChatGPT didn't finish registering Oneshot. Try again."
        case .clientMismatch: return "ChatGPT returned a different app registration. Try again."
        case .accountMismatch: return "You signed in to a different ChatGPT account. Use \u{201C}Use another account\u{201D} instead."
        case .oauth(let e): return "ChatGPT sign-in failed (\(e))"
        case .badIDToken(let why): return "Couldn't verify the ChatGPT sign-in (\(why))"
        case .notConnected: return "Connect ChatGPT in Settings"
        case .planNotEnabled: return "ChatGPT plan use isn't enabled"
        case .needsSignIn: return "Sign in to ChatGPT again in Settings"
        case .usageLimit: return "ChatGPT usage limit reached"
        case .notEligible: return "Your ChatGPT plan can't be used in apps"
        case .unavailable: return "ChatGPT is busy. Try again in a moment."
        case .api(let code, let msg): return "ChatGPT \(code): \(msg.prefix(90))"
        }
    }
}

// MARK: - Local storage (Application Support/Oneshot/chatgpt.json, 0600)

struct ChatGPTTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scopes: [String]
    var savedAt: Date
}

struct ChatGPTRegistration: Codable {
    var clientID: String
    var subject: String
    var email: String?
    var idToken: String?          // kept for id_token_hint on the next sign-in
    var tokens: ChatGPTTokens?
    var planEnabled: Bool { tokens?.scopes.contains(SIWC.planScope) ?? false }
}

struct ChatGPTStore: Codable {
    var hostID: String
    var registrations: [ChatGPTRegistration] = []
    var activeSubject: String?
    /// Issued by a new registration whose code exchange didn't finish; reused on the next attempt.
    var pendingClientID: String?

    static var url: URL { Secrets.dir.appendingPathComponent("chatgpt.json") }

    static func load() -> ChatGPTStore {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder.iso.decode(ChatGPTStore.self, from: data) { return s }
        // One opaque, stable host ID per installation, created before the first sign-in.
        let s = ChatGPTStore(hostID: "urn:uuid:" + UUID().uuidString.lowercased())
        s.save()
        return s
    }

    func save() {
        guard let data = try? JSONEncoder.iso.encode(self) else { return }
        let tmp = Self.url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try? FileManager.default.replaceItemAt(Self.url, withItemAt: tmp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    var active: ChatGPTRegistration? { registrations.first { $0.subject == activeSubject } }

    mutating func upsert(_ r: ChatGPTRegistration) {
        if let i = registrations.firstIndex(where: { $0.subject == r.subject && $0.clientID == r.clientID }) { registrations[i] = r }
        else { registrations.append(r) }
    }
}

struct ChatGPTModel: Decodable, Identifiable, Hashable {
    let slug: String
    let display_name: String?
    let visibility: String?
    var id: String { slug }
    var name: String { display_name ?? slug }
}

// MARK: - Account

@MainActor
final class ChatGPTAccount: ObservableObject {
    static let shared = ChatGPTAccount()

    @Published private(set) var email: String?
    @Published private(set) var connected = false
    @Published private(set) var planEnabled = false
    @Published private(set) var waiting = false
    @Published private(set) var models: [ChatGPTModel] = []
    @Published var error: String?
    /// Set when ChatGPT says the plan (or this app's allowance) is used up.
    @Published var limitReached = false

    private var store = ChatGPTStore.load()
    private var signInTask: Task<Void, Never>?
    private var refreshTask: Task<ChatGPTTokens, Error>?
    private var callback: LoopbackCallback?

    /// True when text requests should go to the user's ChatGPT plan.
    var ready: Bool { connected && planEnabled && Prefs.shared.useChatGPTPlan }
    var selectedModel: String { Prefs.shared.chatgptModel.isEmpty ? (Self.pickDefault(models)?.slug ?? "") : Prefs.shared.chatgptModel }

    private init() {
        publish()
        if connected { Task { await loadModels() } }
    }

    private func publish() {
        let r = store.active
        email = r?.email
        connected = r?.tokens != nil
        planEnabled = r?.planEnabled ?? false
    }

    // MARK: Sign in

    /// Opens the browser. Reuses the saved registration unless the user asks for another account.
    func connect(anotherAccount: Bool = false) {
        guard signInTask == nil else { return }
        error = nil
        waiting = true
        signInTask = Task { [weak self] in
            await self?.signIn(anotherAccount: anotherAccount)
            self?.waiting = false
            self?.signInTask = nil
        }
    }

    func cancelSignIn() {
        callback?.fail(ChatGPTError.cancelled)
    }

    private func signIn(anotherAccount: Bool) async {
        do {
            let saved = anotherAccount ? nil : (store.active ?? store.registrations.last)
            let reuseClient = saved?.clientID ?? (anotherAccount ? nil : store.pendingClientID)
            let server = try LoopbackCallback()
            callback = server
            defer { server.stop(); callback = nil }
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)/auth/callback"
            let state = Self.random(32), nonce = Self.random(32), verifier = Self.random(64)
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

            var q: [(String, String)] = [
                ("client_id", reuseClient ?? SIWC.dynamicClient),
                ("ext_agent_host_id", store.hostID),
                ("response_type", "code"),
                ("redirect_uri", redirect),
                ("scope", SIWC.scopes),
                ("resource", SIWC.resource),
                ("state", state),
                ("nonce", nonce),
                ("code_challenge_method", "S256"),
                ("code_challenge", challenge),
            ]
            if reuseClient == nil { q.append(("agent_name_hint", SIWC.appName)) }
            if let saved, reuseClient == saved.clientID {
                if let hint = saved.idToken { q.append(("id_token_hint", hint)) }
                if let email = saved.email { q.append(("login_hint", email)) }
            }
            NSWorkspace.shared.open(Self.url(SIWC.authorize, q))

            let cb = try await server.wait(timeout: 300)
            guard cb["state"] == state else { throw ChatGPTError.stateMismatch }
            if let e = cb["error"] { throw e == "access_denied" ? ChatGPTError.declined : ChatGPTError.oauth(e) }
            guard let code = cb["code"], !code.isEmpty else { throw ChatGPTError.oauth("no code") }

            let clientID: String
            if let reuseClient {
                if let c = cb["client_id"], !c.isEmpty, c != reuseClient { throw ChatGPTError.clientMismatch }
                clientID = reuseClient
            } else {
                guard let c = cb["client_id"], !c.isEmpty, c != SIWC.dynamicClient else { throw ChatGPTError.registrationIncomplete }
                clientID = c
                store.pendingClientID = c   // keep it even if the exchange below fails
                store.save()
            }

            let resp = try await Self.tokenRequest([
                ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
                ("code_verifier", verifier), ("redirect_uri", redirect), ("resource", SIWC.resource),
            ])
            guard let idToken = resp.id_token else { throw ChatGPTError.badIDToken("missing") }
            let who = try await IDToken.verify(idToken, clientID: clientID, nonce: nonce)
            if let saved, saved.clientID == clientID, saved.subject != who.subject { throw ChatGPTError.accountMismatch }

            var reg = store.registrations.first { $0.clientID == clientID && $0.subject == who.subject }
                ?? ChatGPTRegistration(clientID: clientID, subject: who.subject)
            reg.email = who.email ?? reg.email
            reg.idToken = idToken
            reg.tokens = resp.tokens(previous: nil)
            store.upsert(reg)
            store.activeSubject = who.subject
            if store.pendingClientID == clientID { store.pendingClientID = nil }
            store.save()
            limitReached = false
            publish()
            NSApp.activate(ignoringOtherApps: true)
            await loadModels()
            if planEnabled { welcomeOnce() }
        } catch ChatGPTError.cancelled {
            error = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// First connection only: "You're using your ChatGPT plan".
    private func welcomeOnce() {
        let key = "chatgptWelcomed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let a = NSAlert()
        a.messageText = "You're using your ChatGPT plan"
        a.informativeText = "Eligible usage in Oneshot uses your ChatGPT plan: cleaning up what you say and Command mode. Manage usage in your ChatGPT settings."
        a.addButton(withTitle: "Got it")
        a.addButton(withTitle: "Manage usage")
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(SIWC.manageUsage) }
    }

    // MARK: Sign out

    /// Revokes the refresh token, then forgets this account's tokens (the registration and host ID stay).
    func disconnect() async -> Bool {
        guard var reg = store.active else { return true }
        var revoked = true
        if let rt = reg.tokens?.refreshToken {
            revoked = false
            for attempt in 0..<3 {
                var req = URLRequest(url: SIWC.revoke)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = Self.form([("token", rt), ("token_type_hint", "refresh_token"), ("client_id", reg.clientID)])
                if let (_, resp) = try? await URLSession.shared.data(for: req), let h = resp as? HTTPURLResponse {
                    if h.statusCode == 200 { revoked = true; break }
                    if h.statusCode < 500 { break }
                }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 600_000_000)
            }
        }
        reg.tokens = nil
        reg.idToken = nil
        store.upsert(reg)
        store.activeSubject = nil
        store.save()
        models = []
        limitReached = false
        publish()
        return revoked
    }

    // MARK: Tokens

    /// A valid access token, refreshed near expiry. Refreshes are serialized so the rotating token never races.
    func accessToken() async throws -> String {
        guard let reg = store.active, let t = reg.tokens else { throw ChatGPTError.notConnected }
        if t.expiresAt.timeIntervalSinceNow > 120 { return t.accessToken }
        return try await refresh().accessToken
    }

    @discardableResult
    func refresh() async throws -> ChatGPTTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let reg = store.active, let old = reg.tokens, let rt = old.refreshToken else { throw ChatGPTError.needsSignIn }
        let task = Task<ChatGPTTokens, Error> {
            do {
                let resp = try await Self.tokenRequest([
                    ("grant_type", "refresh_token"), ("client_id", reg.clientID), ("refresh_token", rt), ("resource", SIWC.resource),
                ])
                return resp.tokens(previous: old)
            } catch ChatGPTError.oauth(let code) where Self.deadRefreshCodes.contains(code) {
                throw ChatGPTError.needsSignIn
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            if var r = store.active, r.clientID == reg.clientID { r.tokens = fresh; store.upsert(r); store.save() }
            publish()
            return fresh
        } catch ChatGPTError.needsSignIn {
            // The session is gone (expired or disconnected in ChatGPT settings): drop the tokens, keep the registration.
            if var r = store.active { r.tokens = nil; store.upsert(r); store.save() }
            publish()
            throw ChatGPTError.needsSignIn
        }
    }

    private static let deadRefreshCodes: Set<String> = ["invalid_grant", "invalid_refresh_token", "token_expired",
                                                         "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]

    // MARK: Models

    func loadModels() async {
        guard connected, planEnabled else { models = []; return }
        do {
            let token = try await accessToken()
            var req = URLRequest(url: SIWC.api.appendingPathComponent("models"))
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try ChatGPTClient.check(resp, data)
            struct List: Decodable { let models: [ChatGPTModel] }
            models = try JSONDecoder().decode(List.self, from: data).models.filter { $0.visibility == nil || $0.visibility == "list" }
        } catch {
            NSLog("Oneshot: couldn't list ChatGPT models: \(error.localizedDescription)")
        }
    }

    /// Cleanup needs speed more than depth: prefer the lightest model the account offers.
    static func pickDefault(_ models: [ChatGPTModel]) -> ChatGPTModel? {
        for hint in ["luna", "mini", "nano", "terra", "sol"] {
            if let m = models.first(where: { $0.slug.lowercased().contains(hint) }) { return m }
        }
        return models.first
    }

    // MARK: HTTP helpers

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double?
        let scope: String?
        func tokens(previous: ChatGPTTokens?) -> ChatGPTTokens {
            let scopes = scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
            return ChatGPTTokens(accessToken: access_token, refreshToken: refresh_token ?? previous?.refreshToken,
                                 expiresAt: Date().addingTimeInterval(expires_in ?? 3600), scopes: scopes, savedAt: Date())
        }
    }

    static func tokenRequest(_ fields: [(String, String)]) async throws -> TokenResponse {
        var req = URLRequest(url: SIWC.token)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(fields)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ChatGPTError.oauth("no response") }
        guard http.statusCode == 200 else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (obj?["error"] as? String) ?? ((obj?["error"] as? [String: Any])?["code"] as? String) ?? "http_\(http.statusCode)"
            throw ChatGPTError.oauth(code)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
    static func form(_ fields: [(String, String)]) -> Data { Data(fields.map { enc($0.0) + "=" + enc($0.1) }.joined(separator: "&").utf8) }
    static func url(_ base: URL, _ q: [(String, String)]) -> URL {
        URL(string: base.absoluteString + "?" + q.map { enc($0.0) + "=" + enc($0.1) }.joined(separator: "&"))!
    }
    static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

// MARK: - Inference (Responses API, streamed, never stored)

/// Anything that can turn a system prompt + user text into text: an OpenAI key or the user's ChatGPT plan.
protocol TextModel {
    func chat(model: String, system: String, user: String, maxTokens: Int) async throws -> String
}

extension OpenAIClient: TextModel {}

struct ChatGPTClient: TextModel {
    let token: () async throws -> String
    var onUnauthorized: () async throws -> Void = {}

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 180
        return URLSession(configuration: c)
    }()

    /// Cleanup is a light rewrite, so skip reasoning: it roughly halves the wait. Models that
    /// refuse "none" are remembered and asked again with their default effort.
    private static let noReasoning = NSLock()
    nonisolated(unsafe) private static var rejectsNoReasoning: Set<String> = []
    private static func skipsReasoning(_ model: String) -> Bool {
        noReasoning.lock(); defer { noReasoning.unlock() }
        return !rejectsNoReasoning.contains(model)
    }
    private static func markRejects(_ model: String) {
        noReasoning.lock(); rejectsNoReasoning.insert(model); noReasoning.unlock()
    }

    func chat(model: String, system: String, user: String, maxTokens: Int) async throws -> String {
        do { return try await withEffortFallback(model: model, system: system, user: user) }
        catch ChatGPTError.api(401, _) {
            try await onUnauthorized()      // refresh once, then retry
            return try await withEffortFallback(model: model, system: system, user: user)
        }
    }

    private func withEffortFallback(model: String, system: String, user: String) async throws -> String {
        guard Self.skipsReasoning(model) else { return try await stream(model: model, system: system, user: user, noReasoning: false) }
        do { return try await stream(model: model, system: system, user: user, noReasoning: true) }
        catch ChatGPTError.api(400, let message) where message.localizedCaseInsensitiveContains("reasoning") || message.localizedCaseInsensitiveContains("effort") {
            Self.markRejects(model)
            return try await stream(model: model, system: system, user: user, noReasoning: false)
        }
    }

    private func stream(model: String, system: String, user: String, noReasoning: Bool) async throws -> String {
        var req = URLRequest(url: SIWC.api.appendingPathComponent("responses"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": [["role": "user", "content": user]],
            "store": false,
            "stream": true,
        ]
        if noReasoning { body["reasoning"] = ["effort": "none"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await Self.session.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
            try Self.check(resp, data)
        }
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                text += obj["delta"] as? String ?? ""
            case "response.completed":
                return text
            case "response.failed", "error":
                let err = ((obj["response"] as? [String: Any])?["error"] as? [String: Any]) ?? (obj["error"] as? [String: Any]) ?? obj
                throw Self.mapped(code: err["code"] as? String, status: 0, message: err["message"] as? String ?? type)
            case "response.incomplete":
                throw ChatGPTError.api(0, "The response was cut short")
            default: break
            }
        }
        throw ChatGPTError.api(0, "The response ended early")
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw ChatGPTError.api(0, "no response") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        let message = err?["message"] as? String ?? obj?["detail"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        throw mapped(code: err?["code"] as? String, status: http.statusCode, message: message)
    }

    static func mapped(code: String?, status: Int, message: String) -> ChatGPTError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "subscription_sharing_user_not_eligible": return .notEligible
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .unavailable
        case "subscription_sharing_invalid_user": return .needsSignIn
        default: return .api(status, message)
        }
    }
}

extension ChatGPTAccount {
    /// A client bound to the active account, for Cleaner.
    nonisolated func client() -> ChatGPTClient {
        ChatGPTClient(token: { try await self.accessToken() }, onUnauthorized: { _ = try await self.refresh() })
    }

    /// Records plan-level problems so Settings and Home can explain them.
    func note(_ error: Error) {
        switch error as? ChatGPTError {
        case .usageLimit: limitReached = true
        case .needsSignIn: publish()
        default: break
        }
    }
}

// MARK: - ID token verification (RS256 against OpenAI's JWKS)

enum IDToken {
    struct Identity { let subject: String; let email: String? }
    private static var keys: [String: SecKey] = [:]

    static func verify(_ jwt: String, clientID: String, nonce: String) async throws -> Identity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let hData = Data(base64URL: parts[0]), let pData = Data(base64URL: parts[1]),
              let sig = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: hData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: pData) as? [String: Any] else { throw ChatGPTError.badIDToken("format") }
        guard header["alg"] as? String == "RS256", let kid = header["kid"] as? String else { throw ChatGPTError.badIDToken("algorithm") }
        let key = try await publicKey(kid)
        var err: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, sig as CFData, &err)
        else { throw ChatGPTError.badIDToken("signature") }

        guard claims["iss"] as? String == SIWC.issuer else { throw ChatGPTError.badIDToken("issuer") }
        let aud = (claims["aud"] as? String).map { [$0] } ?? (claims["aud"] as? [String]) ?? []
        guard aud.contains(clientID) else { throw ChatGPTError.badIDToken("audience") }
        guard let exp = claims["exp"] as? Double, exp > Date().timeIntervalSince1970 - 60 else { throw ChatGPTError.badIDToken("expired") }
        guard claims["nonce"] as? String == nonce else { throw ChatGPTError.badIDToken("nonce") }
        guard let sub = claims["sub"] as? String, !sub.isEmpty else { throw ChatGPTError.badIDToken("subject") }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        return Identity(subject: sub, email: claims["email"] as? String ?? profile?["email"] as? String)
    }

    private static func publicKey(_ kid: String) async throws -> SecKey {
        if let k = keys[kid] { return k }
        let (data, _) = try await URLSession.shared.data(from: SIWC.jwks)
        guard let set = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = set["keys"] as? [[String: Any]] else {
            throw ChatGPTError.badIDToken("keys")
        }
        for jwk in list {
            guard jwk["kty"] as? String == "RSA", let id = jwk["kid"] as? String,
                  let n = (jwk["n"] as? String).flatMap(Data.init(base64URL:)), let e = (jwk["e"] as? String).flatMap(Data.init(base64URL:)) else { continue }
            let der = DER.sequence(DER.integer(n) + DER.integer(e))   // PKCS#1 RSAPublicKey
            let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            if let k = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) { keys[id] = k }
        }
        guard let k = keys[kid] else { throw ChatGPTError.badIDToken("unknown key") }
        return k
    }
}

private enum DER {
    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func integer(_ d: Data) -> Data {
        var v = Data(d.drop(while: { $0 == 0 }))
        if v.isEmpty || v.first! & 0x80 != 0 { v.insert(0, at: 0) }
        return Data([0x02]) + length(v.count) + v
    }
    static func sequence(_ d: Data) -> Data { Data([0x30]) + length(d.count) + d }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

// MARK: - Loopback callback (http://127.0.0.1:<port>/auth/callback)

final class LoopbackCallback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "oneshot.chatgpt.callback")
    private var result: Result<[String: String], Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            // stateUpdateHandler runs on `queue`, so this flag is only touched there.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if !once.done { once.done = true; cont.resume(returning: self?.listener.port?.rawValue ?? 0) }
                case .failed(let e): if !once.done { once.done = true; cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] c in self?.handle(c) }
            listener.start(queue: queue)
        }
    }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.deliver(.failure(ChatGPTError.timedOut)) }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let r = self.result { cont.resume(with: r) } else { self.waiter = cont }
            }
        }
    }

    func fail(_ error: Error) { queue.async { self.deliver(.failure(error)) } }
    func stop() { listener.cancel() }

    private func deliver(_ r: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = r
        waiter?.resume(with: r)
        waiter = nil
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { c.cancel(); return }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : ""
            guard let comps = URLComponents(string: "http://127.0.0.1" + target), comps.path == "/auth/callback" else {
                self.respond(c, status: "404 Not Found", body: "Not found")
                return
            }
            var q: [String: String] = [:]
            for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
            let ok = q["error"] == nil
            self.respond(c, status: "200 OK", body: Self.page(ok ? "You're connected" : "Sign-in cancelled",
                                                              ok ? "Oneshot can use your ChatGPT plan. You can close this tab." : "You can close this tab and try again from Oneshot."))
            self.deliver(.success(q))
        }
    }

    private func respond(_ c: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        c.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
    }

    private static func page(_ title: String, _ text: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Oneshot</title>
        <body style="font:15px -apple-system,system-ui;background:#f6f2ec;color:#141216;display:grid;place-items:center;height:100vh;margin:0">
        <div style="text-align:center"><h1 style="font-size:24px;letter-spacing:-.02em;margin:0 0 8px">\(title)</h1><p style="color:#6b6570;margin:0">\(text)</p></div>
        """
    }
}
