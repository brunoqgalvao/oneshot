import Foundation

enum CloudError: LocalizedError {
    case server(status: Int, code: String, message: String)
    var errorDescription: String? {
        if case .server(_, _, let m) = self { return m }
        return nil
    }
    var code: String { if case .server(_, let c, _) = self { return c }; return "" }
    var status: Int { if case .server(let s, _, _) = self { return s }; return 0 }
}

struct CloudUsage: Codable, Equatable {
    var usedSeconds: Double
    var limitSeconds: Double
    var remainingMinutes: Int { max(0, Int(((limitSeconds - usedSeconds) / 60).rounded(.down))) }
    var limitMinutes: Int { Int((limitSeconds / 60).rounded()) }
}

struct DictateMeta: Encodable {
    var mode: String
    var durationSeconds: Double
    var language: String
    var vocabulary: [String]
    var destination: String
    var appName: String?
    var contextBefore: String?
    var selection: String?
    var cleanup: Bool
}

struct DictateResult: Decodable {
    var raw: String
    var text: String
    var mode: String
    var usage: CloudUsage?
}

/// Talks to the Murmur server, which holds the OpenAI key and runs the prompts.
struct CloudClient {
    let base: URL
    let token: String?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 120
        return URLSession(configuration: c)
    }()

    static func prewarm(_ base: URL) {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 10
        session.dataTask(with: req).resume()
    }

    private struct AuthResponse: Decodable { var token: String; var email: String; var usage: CloudUsage }
    private struct MeResponse: Decodable { var email: String; var usage: CloudUsage }

    func auth(create: Bool, email: String, password: String) async throws -> (token: String, email: String, usage: CloudUsage) {
        var req = request(create ? "v1/auth/signup" : "v1/auth/login", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let r: AuthResponse = try await send(req)
        return (r.token, r.email, r.usage)
    }

    func me() async throws -> (email: String, usage: CloudUsage) {
        let r: MeResponse = try await send(request("v1/me", method: "GET"))
        return (r.email, r.usage)
    }

    func logout() async {
        _ = try? await Self.session.data(for: request("v1/auth/logout", method: "POST"))
    }

    func dictate(fileURL: URL, meta: DictateMeta) async throws -> DictateResult {
        let boundary = "murmur-\(UUID().uuidString)"
        var req = request("v1/dictate", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        let metaJSON = String(data: try JSONEncoder().encode(meta), encoding: .utf8) ?? "{}"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"meta\"\r\n\r\n\(metaJSON)\r\n".data(using: .utf8)!)
        let ext = fileURL.pathExtension.lowercased()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.\(ext)\"\r\nContent-Type: \(ext == "wav" ? "audio/wav" : "audio/mp4")\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, resp) = try await Self.session.upload(for: req, from: body)
        try Self.check(resp, data)
        return try JSONDecoder().decode(DictateResult.self, from: data)
    }

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await Self.session.data(for: req)
        try Self.check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw MurmurError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw CloudError.server(status: http.statusCode,
                                    code: obj?["error"] as? String ?? "http_\(http.statusCode)",
                                    message: obj?["message"] as? String ?? "Murmur server error (\(http.statusCode))")
        }
    }
}

/// The signed-in Murmur account. The session token is kept in a 0600 file.
@MainActor
final class Account: ObservableObject {
    static let shared = Account()

    @Published private(set) var email: String?
    @Published private(set) var usage: CloudUsage?
    @Published private(set) var busy = false
    @Published var error: String?
    private(set) var token: String?

    var isSignedIn: Bool { token != nil }

    private var tokenFile: URL { Secrets.dir.appendingPathComponent("session.token") }

    private init() {
        if let s = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            token = t.isEmpty ? nil : t
        }
        email = token == nil ? nil : UserDefaults.standard.string(forKey: "accountEmail")
    }

    var client: CloudClient { CloudClient(base: Prefs.shared.serverURL, token: token) }

    func signIn(create: Bool, email: String, password: String) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let r = try await CloudClient(base: Prefs.shared.serverURL, token: nil)
                .auth(create: create, email: email.trimmingCharacters(in: .whitespaces), password: password)
            save(token: r.token, email: r.email)
            usage = r.usage
        } catch {
            self.error = Self.describe(error)
        }
    }

    func signOut() async {
        let c = client
        save(token: nil, email: nil)
        usage = nil
        await c.logout()
    }

    func refresh() async {
        guard isSignedIn else { return }
        do {
            let r = try await client.me()
            email = r.email
            usage = r.usage
        } catch let e as CloudError where e.status == 401 {
            save(token: nil, email: nil)
        } catch {}
    }

    func update(usage: CloudUsage?) { if let usage { self.usage = usage } }

    /// Called when the server says the session is no longer valid.
    func sessionExpired() { save(token: nil, email: nil); usage = nil }

    private func save(token: String?, email: String?) {
        self.token = token
        self.email = email
        UserDefaults.standard.set(email, forKey: "accountEmail")
        if let token {
            FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.removeItem(at: tokenFile)
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? CloudError { return e.localizedDescription }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet: return "You're offline."
            case .cannotFindHost, .cannotConnectToHost: return "Can't reach the Murmur server."
            case .timedOut: return "The Murmur server took too long to answer."
            default: return "Network error."
            }
        }
        return error.localizedDescription
    }
}
