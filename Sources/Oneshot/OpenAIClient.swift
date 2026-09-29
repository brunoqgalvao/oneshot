import Foundation

struct OpenAIClient {
    let apiKey: String
    var baseURL = URL(string: "https://api.openai.com/v1")!

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.timeoutIntervalForResource = 600
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    /// Opens a TLS connection early (when recording starts) so the upload
    /// doesn't pay for DNS + TLS after the key is released.
    static func prewarm() {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models/whisper-1")!)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        session.dataTask(with: req).resume()
    }

    func transcribe(fileURL: URL, model: String, prompt: String?, language: String?) async throws -> String {
        let boundary = "murmur-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 180   // a 10-minute part can take a while to come back
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        if let language, !language.isEmpty, language != "auto" { field("language", language) }
        let ext = fileURL.pathExtension.lowercased()
        let mime = ext == "wav" ? "audio/wav" : "audio/mp4"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, resp) = try await Self.session.upload(for: req, from: body)
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { throw OneshotError.badResponse }
        return text
    }

    func chat(model: String, system: String, user: String, maxTokens: Int = 2000) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if model.hasPrefix("gpt-5") || model.hasPrefix("o") {
            // Reasoning models: keep latency low.
            payload["reasoning_effort"] = model.hasPrefix("gpt-5-") || model == "gpt-5" ? "minimal" : "none"
            payload["max_completion_tokens"] = maxTokens
        } else {
            payload["temperature"] = 0
            payload["max_tokens"] = maxTokens
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await Self.session.data(for: req)
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw OneshotError.badResponse }
        return content
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw OneshotError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            var msg = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any], let m = err["message"] as? String { msg = m }
            throw OneshotError.http(http.statusCode, msg)
        }
    }
}
