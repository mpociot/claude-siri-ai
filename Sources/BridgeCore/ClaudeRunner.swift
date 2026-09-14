import Foundation
import Synchronization
import Darwin

struct ClaudeEventParser {
    private var emitted = false
    private var resultSeen = false

    mutating func parse(_ line: Data) throws -> BridgeEvent? {
        guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw BridgeFailure("Invalid Claude response.")
        }
        if event["type"] as? String == "stream_event",
           let body = event["event"] as? [String: Any],
           let delta = body["delta"] as? [String: Any],
           delta["type"] as? String == "text_delta",
           let text = delta["text"] as? String, !text.isEmpty {
            emitted = true
            return BridgeEvent(text: text)
        }
        if event["type"] as? String == "result" {
            resultSeen = true
            guard event["is_error"] as? Bool != true else {
                throw BridgeFailure("Claude could not answer. Check your Claude account and try again.")
            }
            if !emitted, let text = event["result"] as? String, !text.isEmpty {
                emitted = true
                return BridgeEvent(text: text)
            }
        }
        return nil
    }

    func finish(exitCode: Int32) throws -> BridgeEvent {
        guard exitCode == 0, resultSeen, emitted else {
            throw BridgeFailure("Claude exited without a complete response. Run claude auth status in Terminal.")
        }
        return BridgeEvent(done: true)
    }
}

// All launch/cancel transitions are locked, including cancellation before launch.
// Blocking pipe reads happen on a Dispatch worker, never the UI/concurrency executor.
private final class ProcessLifetime: Sendable {
    struct State {
        var process: Process?
        var cancelled = false
    }
    private let state = Mutex(State())

    func launch(_ process: Process) throws {
        try state.withLock {
            guard !$0.cancelled else { throw CancellationError() }
            try process.run()
            $0.process = process
        }
    }

    func clear() { state.withLock { $0.process = nil } }

    func cancel() {
        state.withLock {
            $0.cancelled = true
            if let process = $0.process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            state.withLock {
                if let process = $0.process, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
}

struct ClaudeRun: Sendable {
    let events: AsyncThrowingStream<BridgeEvent, Error>
    let cancel: @Sendable () -> Void
}

enum ClaudeRunner {
    static let arguments = [
        "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--no-session-persistence", "--safe-mode", "--disable-slash-commands", "--no-chrome",
        "--system-prompt",
        "You are Claude, answering a request delegated by macOS. Answer the user directly. "
        + "You have no device tools or filesystem access. Never claim to perform a device action. "
        + "For writing requests return only the revised text."
    ]

    static func findExecutable(savedPath: String? = nil) -> URL? {
        let paths = [savedPath, NSHomeDirectory() + "/.local/bin/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    static func start(executable: URL, prompt: String, timeout: TimeInterval = 150) -> ClaudeRun {
        let lifetime = ProcessLifetime()
        let stream = AsyncThrowingStream<BridgeEvent, Error>(bufferingPolicy: .bufferingOldest(128)) { continuation in
            continuation.onTermination = { _ in lifetime.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("claude-bridge-\(UUID())")
                var input: FileHandle?
                let deadline = DispatchWorkItem { lifetime.cancel() }
                defer {
                    deadline.cancel()
                    if process.isRunning { lifetime.cancel(); process.waitUntilExit() }
                    lifetime.clear()
                    try? input?.close()
                    try? output.fileHandleForReading.close()
                    try? output.fileHandleForWriting.close()
                    try? FileManager.default.removeItem(at: cwd)
                }
                do {
                    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let promptURL = cwd.appendingPathComponent("input")
                    try Data(prompt.utf8).write(to: promptURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: promptURL.path)
                    input = try FileHandle(forReadingFrom: promptURL)
                    process.executableURL = executable
                    process.arguments = arguments
                    process.currentDirectoryURL = cwd
                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = [executable.deletingLastPathComponent().path,
                                            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
                    // A GUI launch should not inherit another interactive Claude session.
                    environment.removeValue(forKey: "CLAUDECODE")
                    process.environment = environment
                    process.standardInput = input
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try lifetime.launch(process)
                    try output.fileHandleForWriting.close()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    var pending = Data()
                    var parser = ClaudeEventParser()
                    func emit(_ event: BridgeEvent) throws {
                        switch continuation.yield(event) {
                        case .enqueued: break
                        case .dropped, .terminated: throw CancellationError()
                        @unknown default: throw CancellationError()
                        }
                    }
                    var bytes = [UInt8](repeating: 0, count: 16_384)
                    while true {
                        // FileHandle.read(upToCount:) can fill its buffer before
                        // returning. POSIX read delivers each available pipe chunk.
                        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, 16_384)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw BridgeFailure("Could not read the Claude response.")
                        }
                        pending.append(contentsOf: bytes.prefix(count))
                        guard pending.count <= 2 * 1024 * 1024 else { throw BridgeFailure("Claude response line is too large.") }
                        while let newline = pending.firstIndex(of: 10) {
                            let line = Data(pending[..<newline])
                            pending.removeSubrange(...newline)
                            if !line.isEmpty, let event = try parser.parse(line) { try emit(event) }
                        }
                    }
                    if !pending.isEmpty, let event = try parser.parse(pending) { try emit(event) }
                    process.waitUntilExit()
                    try emit(parser.finish(exitCode: process.terminationStatus))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return ClaudeRun(events: stream, cancel: { lifetime.cancel() })
    }
}
