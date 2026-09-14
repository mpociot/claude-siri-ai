import Foundation

struct BridgeConfiguration: Codable, Sendable {
    let port: UInt16
    let token: String

    static func load(from bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "bridge", withExtension: "json") else {
            throw BridgeFailure("Missing bridge configuration. Rebuild the app.")
        }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard config.port > 0, config.token.utf8.count >= 32 else {
            throw BridgeFailure("Invalid bridge configuration. Rebuild the app.")
        }
        return config
    }
}

struct BridgePrompt: Codable, Sendable {
    let text: String
    var selectedText: String? = nil
    var writingTools: Bool = false

    func cliText() throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeFailure("A text prompt is required.")
        }
        var result = text
        if let selectedText, !selectedText.isEmpty {
            result += "\n\n<selected_text>\n\(selectedText)\n</selected_text>"
        }
        if writingTools { result += "\n\nReturn only the rewritten text, without commentary." }
        return result
    }
}

struct BridgeEvent: Codable, Sendable, Equatable {
    var text: String? = nil
    var error: String? = nil
    var done: Bool? = nil
}

struct BridgeFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Shared with the extension; no credentials or prompts are written to logs.
enum BridgeClient {
    static func test(configuration: BridgeConfiguration) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(configuration.port)/generate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(BridgePrompt(text: "Reply with exactly: Claude bridge works"))
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BridgeFailure("The app's bridge is unavailable.")
        }
        var answer = ""
        var completed = false
        for try await line in bytes.lines {
            let event = try JSONDecoder().decode(BridgeEvent.self, from: Data(line.utf8))
            if let error = event.error { throw BridgeFailure(error) }
            answer += event.text ?? ""
            completed = completed || event.done == true
        }
        guard completed else { throw BridgeFailure("The response was interrupted.") }
        return answer
    }
}
