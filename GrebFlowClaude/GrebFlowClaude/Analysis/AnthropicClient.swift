import Foundation

enum AnthropicError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case permissionDenied(String)
    case modelNotFound(String)
    case requestTooLarge(String)
    case rateLimited(retryAfter: String?)
    case overloaded
    case server(status: Int, message: String)
    case badRequest(String)
    case offline
    case timedOut
    case cancelled
    case malformedResponse
    case refusal(category: String?)
    case truncated

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add an Anthropic API key in Settings first."
        case .invalidAPIKey:
            "Anthropic rejected the API key. Check or replace it in Settings."
        case let .permissionDenied(message):
            "This API key isn't allowed to do that: \(message)"
        case let .modelNotFound(model):
            "The model \(model) isn't available to this API key. Pick another model ID in Settings."
        case let .requestTooLarge(message):
            "The request was too large for the model. \(message)"
        case let .rateLimited(retryAfter):
            if let retryAfter { "Rate limited by Anthropic. Try again in about \(retryAfter) seconds." } else { "Rate limited by Anthropic. Try again in a moment." }
        case .overloaded:
            "Anthropic is overloaded right now. Try again shortly."
        case let .server(status, message):
            "Anthropic returned an error (\(status)): \(message)"
        case let .badRequest(message):
            "Anthropic rejected the request: \(message)"
        case .offline:
            "No internet connection. Dictation and local counts still work; grouping resumes when you retry online."
        case .timedOut:
            "The request timed out."
        case .cancelled:
            "Cancelled."
        case .malformedResponse:
            "Anthropic sent a response GrebFlowClaude couldn't read."
        case let .refusal(category):
            "The model declined this batch\(category.map { " (\($0))" } ?? "")."
        case .truncated:
            "The response hit the output limit before it was finished, so nothing was saved. Retry sends a smaller batch."
        }
    }
}

struct ModelInfo: Decodable, Equatable, Sendable {
    var id: String
    var displayName: String?
    var maxInputTokens: Int?
    var maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case maxInputTokens = "max_input_tokens"
        case maxTokens = "max_tokens"
    }
}

struct MessageResult: Equatable, Sendable {
    var text: String
    var model: String
    var stopReason: String?
    var inputTokens: Int?
    var outputTokens: Int?
}

/// Minimal URLSession client for the Anthropic Messages API. No SDK exists
/// for Swift, so this speaks raw HTTPS. The API key comes from the caller per
/// request and is never logged.
struct AnthropicClient: Sendable {
    static let apiVersion = "2023-06-01"

    var baseURL = URL(string: "https://api.anthropic.com")!
    var session: URLSession
    var timeout: TimeInterval = 120

    init(session: URLSession = .shared) {
        self.session = session
    }

    func model(id: String, apiKey: String) async throws -> ModelInfo {
        let url = baseURL.appending(path: "v1/models/\(id)")
        let data = try await send(makeRequest(url: url, method: "GET", apiKey: apiKey), modelID: id)
        guard let info = try? JSONDecoder().decode(ModelInfo.self, from: data) else { throw AnthropicError.malformedResponse }
        return info
    }

    func countTokens(model: String, system: String, userMessage: String, apiKey: String) async throws -> Int {
        let body: [String: Any] = [
            "model": model,
            "system": system,
            "messages": [["role": "user", "content": userMessage]],
        ]
        var request = makeRequest(url: baseURL.appending(path: "v1/messages/count_tokens"), method: "POST", apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request, modelID: model)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["input_tokens"] as? Int
        else { throw AnthropicError.malformedResponse }
        return tokens
    }

    static func messageBody(model: String, maxTokens: Int, system: String, userMessage: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": userMessage]],
        ]
        // Haiku models think by default. Classification doesn't need it, and
        // turning it off keeps cost and latency down. No server-side
        // fallback either: the app never swaps in another model on its own.
        if model.hasPrefix("claude-haiku") { body["thinking"] = ["type": "disabled"] }
        return body
    }

    func createMessage(model: String, maxTokens: Int, system: String, userMessage: String, apiKey: String) async throws -> MessageResult {
        var request = makeRequest(url: baseURL.appending(path: "v1/messages"), method: "POST", apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.messageBody(
            model: model, maxTokens: maxTokens, system: system, userMessage: userMessage
        ))
        let data = try await send(request, modelID: model)
        return try Self.parseMessage(data)
    }

    /// Reads every text block, skips other block types, and checks the stop
    /// reason before treating the text as a complete answer.
    static func parseMessage(_ data: Data) throws -> MessageResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { throw AnthropicError.malformedResponse }

        let stopReason = json["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw AnthropicError.refusal(category: details?["category"] as? String)
        }
        if stopReason == "max_tokens" { throw AnthropicError.truncated }

        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AnthropicError.malformedResponse }

        let usage = json["usage"] as? [String: Any]
        return MessageResult(
            text: text,
            model: json["model"] as? String ?? "",
            stopReason: stopReason,
            inputTokens: usage?["input_tokens"] as? Int,
            outputTokens: usage?["output_tokens"] as? Int
        )
    }

    private func makeRequest(url: URL, method: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    private func send(_ request: URLRequest, modelID: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw AnthropicError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw AnthropicError.cancelled
            case .timedOut: throw AnthropicError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                throw AnthropicError.offline
            default: throw AnthropicError.server(status: 0, message: error.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.malformedResponse }
        guard !(200..<300).contains(http.statusCode) else { return data }
        throw Self.mapError(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "retry-after"), modelID: modelID)
    }

    static func mapError(status: Int, data: Data, retryAfter: String?, modelID: String) -> AnthropicError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let type = error?["type"] as? String ?? ""
        let message = error?["message"] as? String ?? "No details."

        switch status {
        case 401: return .invalidAPIKey
        case 403: return .permissionDenied(message)
        case 404: return .modelNotFound(modelID)
        case 413: return .requestTooLarge(message)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 529: return .overloaded
        case 400:
            if type == "request_too_large" || message.localizedCaseInsensitiveContains("prompt is too long")
                || message.localizedCaseInsensitiveContains("too many tokens") {
                return .requestTooLarge(message)
            }
            return .badRequest(message)
        default:
            if type == "overloaded_error" { return .overloaded }
            return .server(status: status, message: message)
        }
    }
}
