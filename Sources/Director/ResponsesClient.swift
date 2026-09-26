import Core
import Foundation

public protocol ResponsesTransport: Sendable {
    func send(_ body: Data) async throws -> (status: Int, body: Data)
}

public struct OpenAITransport: ResponsesTransport {
    let apiKey: String
    let timeout: TimeInterval
    public init(apiKey: String, timeout: TimeInterval = 180) { self.apiKey = apiKey; self.timeout = timeout }

    public func send(_ body: Data) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Sends the same Responses JSON through AK14's Worker; the provider key stays on the server.
public struct WorkerTransport: ResponsesTransport {
    public let endpoint: URL
    public let inviteToken: String
    public let timeout: TimeInterval
    let session: URLSession

    public init(endpoint: URL, inviteToken: String, timeout: TimeInterval = 180, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.inviteToken = inviteToken
        self.timeout = timeout
        self.session = session
    }

    public func send(_ body: Data) async throws -> (status: Int, body: Data) {
        let host = endpoint.host?.lowercased() ?? ""
        guard endpoint.scheme == "https" ||
                (endpoint.scheme == "http" && (host == "localhost" || host == "127.0.0.1")) else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: endpoint.appending(path: "v1/responses"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(inviteToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

public enum ContentPart: Sendable {
    case text(String)
    case image(jpeg: Data, assetID: AssetID, detail: String)
}

public struct Usage: Codable, Sendable, Equatable {
    public var input = 0, cached = 0, output = 0, reasoning = 0
}

public struct ResponsesResult: Sendable {
    public let outputText: String
    public let usage: Usage
    public let responseID: String?
    public let latencySeconds: Double
    public let retryCount: Int
    public let imageCount: Int
    public let imageBytes: Int
    /// Request with image data replaced by thumbnail references, and the raw response.
    public let redactedRequest: JSONValue
    public let rawResponse: JSONValue?
}

public enum DirectorError: Error, CustomStringConvertible {
    case auth(Int), http(Int, String), incomplete(String), refusal(String), transport(String), noOutput, invalid([String])
    public var description: String {
        switch self {
        case .auth(let c): "authentication failed (HTTP \(c))"
        case .http(let c, let m): "HTTP \(c): \(m)"
        case .incomplete(let r): "response incomplete: \(r)"
        case .refusal(let r): "model refused: \(r)"
        case .transport(let m): "network error: \(m)"
        case .noOutput: "response had no output text"
        case .invalid(let issues): "invalid output: \(issues.prefix(5).joined(separator: "; "))"
        }
    }
}

/// A failed call with whatever was billed and observed, so telemetry and llm/ artifacts stay complete.
public struct CallFailure: Error, CustomStringConvertible {
    public let error: DirectorError
    public let usage: Usage
    public let retryCount: Int
    public let latencySeconds: Double
    public let imageCount: Int
    public let imageBytes: Int
    public let redactedRequest: JSONValue
    public let rawResponse: JSONValue?
    public var description: String { error.description }
}

public struct ResponsesClient: Sendable {
    public let transport: any ResponsesTransport
    public let model: String
    let sleep: @Sendable (Double) async -> Void

    /// Throws `CallFailure`.
    public init(transport: any ResponsesTransport, model: String = "gpt-6-luna",
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport; self.model = model; self.sleep = sleep
    }

    public func call(system: String, content: [ContentPart], schemaName: String, schema: JSONValue,
                     reasoning: String = "low", maxOutputTokens: Int = 16000) async throws -> ResponsesResult {
        func body(redacted: Bool) -> JSONValue {
            let parts: [JSONValue] = content.map {
                switch $0 {
                case .text(let t): return .object([("type", .string("input_text")), ("text", .string(t))])
                case .image(let jpeg, let id, let detail):
                    let url = redacted ? "thumbnail:\(id.rawValue)" : "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
                    return .object([("type", .string("input_image")), ("image_url", .string(url)), ("detail", .string(detail))])
                }
            }
            return .object([
                ("model", .string(model)),
                ("input", .array([
                    .object([("role", .string("system")), ("content", .string(system))]),
                    .object([("role", .string("user")), ("content", .array(parts))]),
                ])),
                ("text", .object([("format", .object([("type", .string("json_schema")), ("name", .string(schemaName)),
                                                      ("strict", .bool(true)), ("schema", schema)]))])),
                ("reasoning", .object([("effort", .string(reasoning))])),
                ("max_output_tokens", .int(maxOutputTokens)),
                ("store", .bool(false)),
            ])
        }
        let data = try JSONEncoder().encode(body(redacted: false))
        var images = 0, imageBytes = 0
        for case .image(let jpeg, _, _) in content { images += 1; imageBytes += jpeg.count }

        let clock = ContinuousClock(), start = clock.now
        var retries = 0
        let backoff = [1.0, 3.0]
        func failure(_ e: DirectorError, _ usage: Usage = Usage(), _ raw: JSONValue? = nil) -> CallFailure {
            CallFailure(error: e, usage: usage, retryCount: retries, latencySeconds: (clock.now - start).seconds,
                        imageCount: images, imageBytes: imageBytes, redactedRequest: body(redacted: true), rawResponse: raw)
        }
        while true {
            let status: Int, responseData: Data
            do {
                (status, responseData) = try await transport.send(data)
            } catch {
                if retries < backoff.count { await sleep(jitter(backoff[retries])); retries += 1; continue }
                throw failure(.transport((error as NSError).localizedDescription))
            }
            let raw = try? JSONDecoder().decode(JSONValue.self, from: responseData)
            if status == 429 || status >= 500 {
                if retries < backoff.count { await sleep(jitter(backoff[retries])); retries += 1; continue }
                throw failure(.http(status, Self.errorMessage(responseData)), Usage(), raw)
            }
            if status == 401 || status == 403 { throw failure(.auth(status)) }
            if status >= 400 || status == 0 { throw failure(.http(status, Self.errorMessage(responseData)), Usage(), raw) }

            guard let json = raw else { throw failure(.noOutput) }
            let u = json["usage"]
            let usage = Usage(input: u?["input_tokens"]?.intValue ?? 0,
                              cached: u?["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0,
                              output: u?["output_tokens"]?.intValue ?? 0,
                              reasoning: u?["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0)
            if let s = json["status"]?.stringValue, s != "completed" {
                throw failure(.incomplete(json["incomplete_details"]?["reason"]?.stringValue ?? s), usage, json)
            }
            var text: String?
            for item in json["output"]?.arrayValue ?? [] where item["type"]?.stringValue == "message" {
                for c in item["content"]?.arrayValue ?? [] {
                    if c["type"]?.stringValue == "refusal" { throw failure(.refusal(c["refusal"]?.stringValue ?? ""), usage, json) }
                    if c["type"]?.stringValue == "output_text" { text = (text ?? "") + (c["text"]?.stringValue ?? "") }
                }
            }
            guard let text else { throw failure(.noOutput, usage, json) }
            return ResponsesResult(outputText: text, usage: usage, responseID: json["id"]?.stringValue,
                                   latencySeconds: (clock.now - start).seconds, retryCount: retries,
                                   imageCount: images, imageBytes: imageBytes,
                                   redactedRequest: body(redacted: true), rawResponse: json)
        }
    }

    private func jitter(_ s: Double) -> Double { s * Double.random(in: 0.7...1.3) }

    static func errorMessage(_ data: Data) -> String {
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        return json?["error"]?["message"]?.stringValue ?? String(decoding: data.prefix(200), as: UTF8.self)
    }
}

public enum Pricing {
    public static let version = "openai-2026-09"
    /// USD per 1M tokens for gpt-6-luna.
    public static let inputPerM = 0.10, cachedPerM = 0.01, outputPerM = 0.50

    public static func estimate(_ u: Usage) -> Double {
        (Double(u.input - u.cached) * inputPerM + Double(u.cached) * cachedPerM + Double(u.output) * outputPerM) / 1_000_000
    }
}
