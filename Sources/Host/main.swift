import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server = BridgeServer()
    private var configuration: BridgeConfiguration?
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "Starting bridge…")
    private let cliLabel = NSTextField(wrappingLabelWithString: "")
    private let result = NSTextField(wrappingLabelWithString: "")
    private var testButton: NSButton!
    private var discoveryButton: NSButton!
    private var restoreButton: NSButton!
    private var loginButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--smoke-test") {
            Task {
                do {
                    print(try await BridgeClient.test(configuration: BridgeConfiguration.load()))
                    exit(0)
                } catch {
                    print("Bridge test failed: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }
        makeMenu()
        makeWindow()
        server.statusChanged = { [weak self] in self?.status.stringValue = $0 }
        updateExecutable()
        do {
            let config = try BridgeConfiguration.load()
            configuration = config
            try server.start(configuration: config)
        } catch { status.stringValue = error.localizedDescription }
        if !CommandLine.arguments.contains("--background") { showWindow() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await server.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "Claude")
        let menu = NSMenu()
        menu.addItem(withTitle: "Claude Settings…", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Bridge", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Claude Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let top = NSMenuItem()
        top.submenu = appMenu
        mainMenu.addItem(top)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let editTop = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editTop.submenu = edit
        mainMenu.addItem(editTop)
        NSApp.mainMenu = mainMenu
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 570),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Claude"
        window.isReleasedWhenClosed = false
        window.center()
        let title = NSTextField(labelWithString: "Claude for Siri")
        title.font = .systemFont(ofSize: 27, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Use your signed-in Claude Code account from Spotlight. Keep this app running in the menu bar.")
        intro.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13, weight: .medium)
        cliLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cliLabel.textColor = .secondaryLabelColor
        cliLabel.isSelectable = true
        let choose = button("Choose Claude CLI…", #selector(chooseCLI))
        testButton = button("Test Connection", #selector(testConnection))
        let tools = NSStackView(views: [choose, testButton])
        tools.spacing = 10
        discoveryButton = button("Enable in Spotlight…", #selector(enableDiscovery))
        restoreButton = button("Restore Normal Discovery", #selector(restoreDiscovery))
        let discovery = NSStackView(views: [discoveryButton, restoreButton])
        discovery.spacing = 10
        let warning = NSTextField(wrappingLabelWithString: "Experimental · macOS 27 with SIP and AMFI disabled. Enabling discovery asks for administrator authentication and restarts Siri/Spotlight. Repeat after a restart.")
        warning.font = .systemFont(ofSize: 12)
        warning.textColor = .secondaryLabelColor
        let instructions = NSTextField(wrappingLabelWithString: "Press ⌘Space → right-click → Ask… → Claude. Send a prompt and complete Apple's Turn On flow if asked.")
        loginButton = NSButton(checkboxWithTitle: "Open at login", target: self, action: #selector(toggleLogin))
        loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
        result.font = .systemFont(ofSize: 12)
        result.isSelectable = true
        let stack = NSStackView(views: [title, intro, status, cliLabel, tools, warning, discovery,
                                        instructions, loginButton, result])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
        for label in [intro, cliLabel, warning, instructions, result] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }
    @objc private func showWindow() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updateExecutable() {
        server.executable = ClaudeRunner.findExecutable(savedPath: UserDefaults.standard.string(forKey: "claudeExecutable"))
        cliLabel.stringValue = server.executable?.path ?? "Claude CLI not found. Install Claude Code and run claude auth login in Terminal."
    }

    @objc private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.message = "Select the Claude Code executable"
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                self?.result.stringValue = "Choose an executable file."
                return
            }
            UserDefaults.standard.set(url.path, forKey: "claudeExecutable")
            self?.updateExecutable()
        }
    }

    @objc private func testConnection() {
        guard let configuration else { return }
        testButton.isEnabled = false
        result.stringValue = "Asking Claude… This sends a small test prompt using your account."
        Task {
            defer { testButton.isEnabled = true }
            do { result.stringValue = try await BridgeClient.test(configuration: configuration) }
            catch { result.stringValue = error.localizedDescription }
        }
    }

    @objc private func enableDiscovery() { runDiscovery("start") }
    @objc private func restoreDiscovery() { runDiscovery("stop") }
    private func runDiscovery(_ action: String) {
        guard let script = Bundle.main.url(forResource: "discovery-control", withExtension: "sh"),
              let hook = Bundle.main.url(forResource: "DiscoveryOverride", withExtension: "dylib") else {
            result.stringValue = "Discovery resources are missing. Rebuild the app."
            return
        }
        discoveryButton.isEnabled = false
        restoreButton.isEnabled = false
        result.stringValue = "Updating Spotlight discovery…"
        Task {
            defer {
                discoveryButton.isEnabled = true
                restoreButton.isEnabled = true
            }
            do {
                try await Self.runScript(script: script, action: action, hook: hook)
                result.stringValue = action == "start" ? "Ready. Open Spotlight and select Ask… → Claude." : "Normal Siri discovery restored."
            } catch { result.stringValue = error.localizedDescription }
        }
    }

    private nonisolated static func runScript(script: URL, action: String, hook: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [script.path, action, hook.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw BridgeFailure("Discovery was not updated. Authentication may have been cancelled; see the README for requirements.")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @objc private func toggleLogin() {
        Task {
            do {
                if loginButton.state == .on { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
                if SMAppService.mainApp.status == .requiresApproval {
                    result.stringValue = "Allow Claude in System Settings → General → Login Items."
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch {
                loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
                result.stringValue = error.localizedDescription
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
