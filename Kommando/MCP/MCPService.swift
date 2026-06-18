//
//  MCPService.swift
//  Kommando
//
//  Owns the lifecycle of the local control socket that the bundled `kommando-mcp` helper
//  connects to. External AI tools (Cursor, Claude Code, …) spawn the helper over stdio;
//  the helper relays tool calls to this socket, which drives the live terminals.
//

import Foundation

/// Well-known on-disk locations shared between the app and the `kommando-mcp` helper.
/// The helper recomputes these same paths (it runs as the same user), so they must match.
enum MCPPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Kommando", isDirectory: true)
    }

    static var socketPath: String {
        supportDirectory.appendingPathComponent("mcp.sock").path
    }

    static var tokenPath: String {
        supportDirectory.appendingPathComponent("mcp-token").path
    }

    /// The bundled helper executable inside the app bundle (Contents/Helpers/kommando-mcp).
    static var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/kommando-mcp")
    }

    static var helperPath: String { helperURL.path }

    static var helperExists: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
    }
}

@MainActor
final class MCPService {
    static let shared = MCPService()

    private var server: MCPControlServer?
    private(set) var token: String = ""

    var isRunning: Bool { server != nil }

    /// Starts or stops the socket to match the persisted preference. Called at launch.
    func syncWithSettings() {
        // `KOMMANDO_MCP_FORCE=1` starts the server regardless of the stored preference,
        // for headless/automation launches where there's no UI to flip the toggle.
        let forced = ProcessInfo.processInfo.environment["KOMMANDO_MCP_FORCE"] == "1"
        if SettingsStore.shared.mcpServerEnabled || forced {
            start()
        } else {
            stop()
        }
    }

    /// Flips the preference and applies it immediately (used by the Settings toggle).
    func setEnabled(_ enabled: Bool) {
        SettingsStore.shared.mcpServerEnabled = enabled
        syncWithSettings()
    }

    func start() {
        guard server == nil else { return }
        ensureSupportDirectory()
        let token = loadOrCreateToken()
        self.token = token
        let server = MCPControlServer(socketPath: MCPPaths.socketPath, token: token)
        do {
            try server.start()
            self.server = server
            NSLog("[Kommando MCP] control socket listening at \(MCPPaths.socketPath)")
        } catch {
            NSLog("[Kommando MCP] failed to start control socket: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    // MARK: - Token

    private func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(
            at: MCPPaths.supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func loadOrCreateToken() -> String {
        if let existing = try? String(contentsOfFile: MCPPaths.tokenPath, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let token = Self.randomToken()
        try? token.write(toFile: MCPPaths.tokenPath, atomically: true, encoding: .utf8)
        // Restrict to the current user; the token gates socket access.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: MCPPaths.tokenPath)
        return token
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
