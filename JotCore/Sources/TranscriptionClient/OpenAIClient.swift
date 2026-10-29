// Copyright 2026 Slava Staroverov.
// Based on Jot by Ammaar Reshi (Apache License 2.0).
import Foundation

/// OpenAI endpoints and models used by the Jot OpenAI fork.
public struct OpenAIConfig: Sendable, Equatable {
    public var endpoint: URL
    public var transcribeModel: String
    public var cleanupModel: String

    public init(endpoint: URL = URL(string: "https://api.openai.com")!,
                transcribeModel: String = "gpt-transcribe",
                cleanupModel: String = "gpt-6-luna") {
        self.endpoint = endpoint
        self.transcribeModel = transcribeModel
        self.cleanupModel = cleanupModel
    }
}

/// Minimal dependency-free REST transport. Keys are only sent in Authorization
/// headers to the official OpenAI endpoint, never in URLs, logs, or files.
public actor OpenAIClient {
    private let session: URLSession
    private let apiKey: @Sendable () -> String?

    public init(apiKey: @escaping @Sendable () -> String?, session: URLSession? = nil) {
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    public enum KeyCheck: Equatable, Sendable {
        case valid
        case rejected(String?)
        case modelUnavailable(String?)
        case unreachable
    }

    public func validateKey(model: String = "gpt-transcribe",
                            endpoint: URL = OpenAIConfig().endpoint) async -> KeyCheck {
        guard let key = apiKey(), !key.isEmpty else { return .rejected("Missing API key") }
        let safeModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/models/\(safeModel)"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
            switch status {
            case 200: return .valid
            case 401: return .rejected(Self.errorMessage(data))
            case 403, 404: return .modelUnavailable(Self.errorMessage(data))
            case 429, 500...599: return .unreachable
            default: return .rejected(Self.errorMessage(data))
            }
        } catch {
            return .unreachable
        }
    }

    /// Multipart upload of the FLAC produced by Jot's reliable CAF→FLAC pipeline.
    /// The keywords[] fields are literal bias terms, not instructions.
    public func transcribe(flacData: Data, model: String,
                           vocabulary: [String] = [], deadline: TimeInterval,
                           endpoint: URL = OpenAIConfig().endpoint) async throws -> String {
        let boundary = "JotOpenAI-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) {
            body.append(Data(value.utf8))
        }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }

        field("model", model)
        field("response_format", "json")
        // CRLF is a single extended grapheme cluster in Swift, so a String
        // Character check for "\r\n" does not reject a standalone LF.
        // Check Unicode scalars explicitly to reject all newlines and angle brackets.
        let invalidScalars = CharacterSet.newlines.union(CharacterSet(charactersIn: "<>"))
        let hints = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.unicodeScalars.contains(where: { invalidScalars.contains($0) }) }
            .prefix(100)
        if !hints.isEmpty {
            field("prompt", "Dictation, often in Russian and English. Preserve technical names, acronyms and the original language.")
            for term in hints {
                field("keywords[]", String(term.prefix(60)))
            }
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.flac\"\r\n")
        append("Content-Type: audio/flac\r\n\r\n")
        body.append(flacData)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = deadline
        let data = try await send(request, model: model)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcript = object["text"] as? String else {
            throw TranscriptionError.network("Unexpected transcription response")
        }
        return transcript
    }

    /// Optional smart cleanup and tone matching through Responses API.
    /// On failure callers must fall back to the original transcript.
    public func cleanup(prompt: String, model: String, deadline: TimeInterval,
                        endpoint: URL = OpenAIConfig().endpoint) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "input": prompt,
            "store": false,
            "max_output_tokens": 1536
        ]
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/responses"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = deadline
        let data = try await send(request, model: model)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else {
            throw TranscriptionError.network("Unexpected cleanup response")
        }
        let text = output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { item -> String? in
                guard item["type"] as? String == "output_text" else { return nil }
                return item["text"] as? String
            }.joined()
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        return text
    }

    private func send(_ request: URLRequest, model: String) async throws -> Data {
        guard let key = apiKey(), !key.isEmpty else { throw TranscriptionError.auth }
        var signed = request
        signed.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: signed)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw TranscriptionError.offline
            case .timedOut:
                throw TranscriptionError.timeout
            default:
                throw TranscriptionError.network(String(error.code.rawValue))
            }
        } catch {
            throw TranscriptionError.network("Connection failed")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw TranscriptionError.network("No HTTP response")
        }
        let message = Self.errorMessage(data)
        switch status {
        case 200...299: return data
        case 400, 413: throw TranscriptionError.badRequest(message ?? "Invalid audio request")
        case 401: throw TranscriptionError.auth
        case 403, 404: throw TranscriptionError.modelUnavailable(model: model, detail: message)
        case 429:
            let explanation = (message ?? "").lowercased()
            if explanation.contains("quota") || explanation.contains("billing") {
                throw TranscriptionError.rateLimitedDaily
            }
            throw TranscriptionError.rateLimitedTransient
        case 500...599: throw TranscriptionError.network("OpenAI temporarily unavailable: HTTP \(status)")
        default: throw TranscriptionError.network("HTTP \(status)")
        }
    }

    private static func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
