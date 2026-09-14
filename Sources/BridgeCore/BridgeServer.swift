import Foundation
import Network

struct HTTPFailure: Error {
    let status: Int
}

struct HTTPRequestParser {
    static let maximumBody = 256 * 1024
    private var buffer = Data()
    private var length: Int?

    mutating func append(_ data: Data, token: String) throws -> BridgePrompt? {
        buffer.append(data)
        if length == nil {
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 16_384 { throw HTTPFailure(status: 431) }
                return nil
            }
            guard boundary.lowerBound <= 16_384,
                  let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else {
                throw HTTPFailure(status: 400)
            }
            let lines = header.components(separatedBy: "\r\n")
            guard lines.first == "POST /generate HTTP/1.1" else { throw HTTPFailure(status: 404) }
            var headers = [String: String]()
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw HTTPFailure(status: 400) }
                let key = line[..<colon].lowercased()
                guard headers[key] == nil else { throw HTTPFailure(status: 400) }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard Self.equal(headers["authorization"] ?? "", "Bearer \(token)") else {
                throw HTTPFailure(status: 401)
            }
            guard headers["origin"] == nil, headers["transfer-encoding"] == nil else {
                throw HTTPFailure(status: 403)
            }
            guard let value = headers["content-length"], !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let count = Int(value), count > 0, count <= Self.maximumBody else {
                throw HTTPFailure(status: 413)
            }
            length = count
            buffer.removeSubrange(..<boundary.upperBound)
        }
        guard let length else { return nil }
        guard buffer.count <= length else { throw HTTPFailure(status: 400) }
        guard buffer.count == length else { return nil }
        do {
            let prompt = try JSONDecoder().decode(BridgePrompt.self, from: buffer)
            _ = try prompt.cliText()
            return prompt
        } catch { throw HTTPFailure(status: 400) }
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

@MainActor
final class BridgeServer {
    private var listener: NWListener?
    private var sessions = [UUID: Task<Void, Never>]()
    private var connections = [UUID: NWConnection]()
    private var activeRequests = 0
    private(set) var port: UInt16?
    var executable: URL?
    var statusChanged: ((String) -> Void)?

    func start(configuration: BridgeConfiguration) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                      port: NWEndpoint.Port(rawValue: configuration.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    self.statusChanged?("Bridge running · 127.0.0.1:\(self.port ?? configuration.port)")
                case .failed:
                    self.statusChanged?("Could not start bridge. Another copy or the old Python bridge may be using this port.")
                    self.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection, token: configuration.token) }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        for task in sessions.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
    }

    func shutdown() async {
        let pending = Array(sessions.values)
        stop()
        for task in pending { await task.value }
    }

    private func accept(_ connection: NWConnection, token: String) {
        guard listener != nil, sessions.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global(qos: .userInitiated))
        let task = Task { [self] in
            defer {
                connection.cancel()
                connections[id] = nil
                sessions[id] = nil
            }
            // Bound unauthenticated/incomplete requests as well as running requests.
            let deadline = Task {
                try await Task.sleep(for: .seconds(180))
                connection.cancel()
                sessions[id]?.cancel()
            }
            defer { deadline.cancel() }
            var streaming = false
            do {
                var parser = HTTPRequestParser()
                let headerDeadline = Task {
                    try await Task.sleep(for: .seconds(10))
                    connection.cancel()
                }
                defer { headerDeadline.cancel() }
                var prompt: BridgePrompt?
                while prompt == nil {
                    try Task.checkCancellation()
                    let data = try await receive(connection)
                    prompt = try parser.append(data, token: token)
                }
                headerDeadline.cancel()
                guard activeRequests < 2 else { throw HTTPFailure(status: 503) }
                guard let executable else { throw HTTPFailure(status: 503) }
                activeRequests += 1
                defer { activeRequests -= 1 }
                let text = try prompt!.cliText()
                try await send(Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n".utf8), to: connection)
                streaming = true
                let run = ClaudeRunner.start(executable: executable, prompt: text)
                defer { run.cancel() }
                try await withTaskCancellationHandler {
                    for try await event in run.events {
                        try Task.checkCancellation()
                        try await sendEvent(event, to: connection)
                    }
                } onCancel: { run.cancel() }
                try await send(nil, to: connection, complete: true)
            } catch {
                if streaming {
                    try? await sendEvent(BridgeEvent(error: "Claude bridge failed or timed out. Check claude auth status in Terminal, then retry."), to: connection)
                } else {
                    let status = (error as? HTTPFailure)?.status ?? 400
                    try? await send(Data("HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: connection)
                }
                try? await send(nil, to: connection, complete: true)
            }
        }
        sessions[id] = task
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, done, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: BridgeFailure(done ? "Client disconnected." : "Empty request.")) }
            }
        }
    }

    private func sendEvent(_ event: BridgeEvent, to connection: NWConnection) async throws {
        var data = try JSONEncoder().encode(event)
        data.append(10)
        try await send(data, to: connection)
    }

    private func send(_ data: Data?, to connection: NWConnection, complete: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, isComplete: complete, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
