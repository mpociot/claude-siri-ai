import AppIntents
import ExtensionFoundation
import Foundation

@main
struct ClaudeExtension: AppIntentsExtension {}

@_ModelDelegationIntent
struct ClaudeIntent {
    static let title: LocalizedStringResource = "Ask Claude"
    static let description = IntentDescription("Answer questions and rewrite selected text using your signed-in Claude account.")
    static let supportedFeatures: _ModelDelegationFeatures = [.systemAssistant, .writingTools]

    func perform() async throws -> some IntentResult & ReturnsValue<_ModelDelegationResult> {
        let stream = try responseStream
        guard prompt.files.isEmpty else {
            stream.append(text: "This example currently supports text only. Please remove attachments.")
            return .result(value: .complete())
        }
        var selected: String?
        var writing = false
        switch configuration {
        case .systemAssistant(let context): selected = context.selectedText
        case .writingTools(let context):
            selected = context.selectedText
            writing = true
        default: break
        }
        guard let url = Bundle.main.url(forResource: "bridge", withExtension: "json") else {
            throw BridgeError.unavailable
        }
        let config = try JSONDecoder().decode(BridgeConfig.self, from: Data(contentsOf: url))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/generate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Prompt(text: prompt.text, selectedText: selected, writingTools: writing))
        stream.setStatus("Asking Claude…")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BridgeError.unavailable }
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
            if let error = event.error { throw BridgeError.backend(error) }
            if let text = event.text {
                if writing { stream.append(writingToolsOutput: text) }
                else { stream.append(text: text) }
            }
            if event.done == true { completed = true }
        }
        guard completed else { throw BridgeError.unavailable }
        return .result(value: .complete())
    }
}
private struct BridgeConfig: Decodable { let port: Int; let token: String }
private struct Prompt: Encodable { let text: String; let selectedText: String?; let writingTools: Bool }
private struct Event: Decodable { let text: String?; let error: String?; let done: Bool? }
private enum BridgeError: LocalizedError {
    case unavailable, backend(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Claude bridge unavailable or response interrupted. Open the Claude menu bar app and check its connection."
        case .backend(let message): message
        }
    }
}
