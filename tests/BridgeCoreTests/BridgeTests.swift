import Foundation
import Testing
@testable import BridgeCore

@Test func streamedTextIsNotRepeatedByFinalResult() throws {
    var parser = ClaudeEventParser()
    #expect(try parser.parse(Data(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hi"}}}"#.utf8)) == BridgeEvent(text: "Hi"))
    #expect(try parser.parse(Data(#"{"type":"result","result":"Hi","is_error":false}"#.utf8)) == nil)
    #expect(try parser.finish(exitCode: 0) == BridgeEvent(done: true))
}

@Test func finalOnlyResponseAndTruncatedStream() throws {
    var parser = ClaudeEventParser()
    #expect(throws: BridgeFailure.self) { try parser.finish(exitCode: 0) }
    #expect(try parser.parse(Data(#"{"type":"result","result":"Hi"}"#.utf8)) == BridgeEvent(text: "Hi"))
    #expect(throws: BridgeFailure.self) { try parser.finish(exitCode: 1) }
    #expect(throws: BridgeFailure.self) { try parser.parse(Data(#"{"type":"result","is_error":true}"#.utf8)) }
}

private let token = String(repeating: "a", count: 64)
private func request(headers: String = "", authorization: String = token, body: String = #"{"text":"ping","writingTools":false}"#) -> Data {
    Data("POST /generate HTTP/1.1\r\nAuthorization: Bearer \(authorization)\r\nContent-Length: \(body.utf8.count)\r\n\(headers)\r\n\(body)".utf8)
}

@Test func fragmentedRequestAndSelectedText() throws {
    var parser = HTTPRequestParser()
    let data = request(body: #"{"text":"Rewrite","selectedText":"hello","writingTools":true}"#)
    for byte in data.dropLast() { #expect(try parser.append(Data([byte]), token: token) == nil) }
    let parsed = try parser.append(Data([data.last!]), token: token)
    let prompt = try #require(parsed)
    #expect(try prompt.cliText().contains("<selected_text>\nhello"))
    #expect(try prompt.cliText().contains("without commentary"))
}

@Test func rejectsUnauthorizedBrowserAndAmbiguousRequests() {
    for data in [
        request(authorization: "wrong"),
        request(headers: "Origin: http://localhost\r\n"),
        request(headers: "Transfer-Encoding: chunked\r\n"),
        request(headers: "Content-Length: 1\r\n"),
        request(body: #"{"text":"","writingTools":false}"#),
        Data("POST /generate HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: 999999\r\n\r\n".utf8)
    ] {
        var parser = HTTPRequestParser()
        #expect(throws: HTTPFailure.self) { try parser.append(data, token: token) }
    }
}

@Test func toolsAndCustomizationsAreDisabled() {
    let arguments = ClaudeRunner.arguments
    #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
    #expect(arguments.contains("--safe-mode"))
    #expect(arguments.contains("--strict-mcp-config"))
    #expect(!arguments.contains("--dangerously-skip-permissions"))
}

private func fakeCLI(_ script: String) throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID())")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    return path
}

@Test func processStreamsAndChecksExitStatus() async throws {
    let cli = try fakeCLI(#"""
    cat >/dev/null
    printf '%s\n' '{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"pong"}}}' '{"type":"result","result":"pong","is_error":false}'
    """#)
    defer { try? FileManager.default.removeItem(at: cli) }
    let run = ClaudeRunner.start(executable: cli, prompt: "ping", timeout: 5)
    defer { run.cancel() }
    var events = [BridgeEvent]()
    for try await event in run.events { events.append(event) }
    #expect(events == [BridgeEvent(text: "pong"), BridgeEvent(done: true)])
}

@Test func timeoutStopsHungProcess() async throws {
    // exec keeps the fake process and its pipe in one PID.
    let cli = try fakeCLI("exec /bin/sleep 30\n")
    defer { try? FileManager.default.removeItem(at: cli) }
    let started = ContinuousClock.now
    let run = ClaudeRunner.start(executable: cli, prompt: "ping", timeout: 0.1)
    defer { run.cancel() }
    await #expect(throws: (any Error).self) {
        for try await _ in run.events {}
    }
    #expect(started.duration(to: .now) < .seconds(5))
}

@Test func deliversFirstDeltaBeforeProcessExits() async throws {
    let cli = try fakeCLI(#"""
    printf '%s\n' '{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"first"}}}'
    /bin/sleep 2
    printf '%s\n' '{"type":"result","result":"first","is_error":false}'
    """#)
    defer { try? FileManager.default.removeItem(at: cli) }
    let started = ContinuousClock.now
    let run = ClaudeRunner.start(executable: cli, prompt: "ping", timeout: 5)
    defer { run.cancel() }
    var first = true
    for try await event in run.events {
        if first {
            #expect(event.text == "first")
            #expect(started.duration(to: .now) < .seconds(1))
            first = false
        }
    }
}

@Test func cancellationStopsRunningProcess() async throws {
    let cli = try fakeCLI("exec /bin/sleep 30\n")
    defer { try? FileManager.default.removeItem(at: cli) }
    let run = ClaudeRunner.start(executable: cli, prompt: "ping", timeout: 10)
    try await Task.sleep(for: .milliseconds(100))
    let started = ContinuousClock.now
    run.cancel()
    await #expect(throws: (any Error).self) {
        for try await _ in run.events {}
    }
    #expect(started.duration(to: .now) < .seconds(5))
}

@Test @MainActor func nativeHTTPBridgeRoundTrip() async throws {
    let cli = try fakeCLI(#"""
    cat >/dev/null
    printf '%s\n' '{"type":"result","result":"Claude bridge works","is_error":false}'
    """#)
    defer { try? FileManager.default.removeItem(at: cli) }
    let server = BridgeServer()
    server.executable = cli
    try server.start(configuration: BridgeConfiguration(port: 0, token: token))
    defer { server.stop() }
    for _ in 0..<100 {
        if server.port != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let port = try #require(server.port)
    #expect(try await BridgeClient.test(configuration: BridgeConfiguration(port: port, token: token)) == "Claude bridge works")
    var bad = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/generate")!)
    bad.httpMethod = "POST"
    bad.httpBody = Data(#"{"text":"ping","writingTools":false}"#.utf8)
    let (_, response) = try await URLSession.shared.data(for: bad)
    #expect((response as? HTTPURLResponse)?.statusCode == 401)
}
