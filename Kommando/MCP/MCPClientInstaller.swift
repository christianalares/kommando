//
//  MCPClientInstaller.swift
//  Kommando
//
//  Knows how to register the bundled `kommando-mcp` helper with the popular MCP clients
//  (Cursor, VS Code, Claude Desktop, Claude Code, Codex). Each client gets a one-click
//  action where one is reliable, and a copy-paste fallback otherwise.
//

import AppKit
import Foundation

/// A single installable MCP client shown in the settings list.
struct MCPClient: Identifiable {
    /// What the primary button does for this client.
    enum Action: Sendable {
        /// Open a deeplink the client registers (e.g. `cursor://…`).
        case deeplink(URL)
        /// Run a command through the user's login shell so PATH is populated.
        case shell(command: String, display: String)
        /// Merge our entry into a JSON config file we own end-to-end.
        case writeJSON(path: URL)
        /// No automatic path — only offer copy-to-clipboard.
        case manual
    }

    let id: String
    let name: String
    let blurb: String
    let symbol: String
    /// True when the app/CLI is actually present on this machine.
    let isInstalled: Bool
    /// True when Kommando is already registered in this client's config.
    let isConfigured: Bool
    let primary: Action
    /// Text the "Copy" fallback puts on the clipboard (command or config snippet).
    let copyText: String
    /// Caption shown under the copy field describing where the snippet goes.
    let copyHint: String
}

/// Which optional CLIs are reachable on the user's login PATH (probed once, off the main
/// thread, since it requires spawning a shell).
struct MCPDetectedCLIs: Sendable {
    var claude = false
    var codex = false
}

enum MCPInstallError: LocalizedError {
    case shellFailed(code: Int32, output: String)
    case badPath

    var errorDescription: String? {
        switch self {
        case let .shellFailed(code, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Command failed (exit \(code))." : trimmed
        case .badPath:
            return "Couldn't locate the kommando-mcp helper."
        }
    }
}

@MainActor
enum MCPClientInstaller {
    static let serverName = "kommando"

    // MARK: - Client catalog + detection

    /// Builds the client list with accurate install/configured state. The CLI probe needs a
    /// login shell, so it runs off the main thread; everything else is fast file IO.
    static func detect(helperPath: String = MCPPaths.helperPath) async -> [MCPClient] {
        let clis = await Task.detached(priority: .userInitiated) { probeCLIs() }.value
        return buildClients(helperPath: helperPath, clis: clis)
    }

    private static func buildClients(helperPath: String, clis: MCPDetectedCLIs) -> [MCPClient] {
        let q = shellQuote(helperPath)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        let cursorConfig = home.appendingPathComponent(".cursor/mcp.json")
        let vscodeConfig = home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        let claudeCodeConfig = home.appendingPathComponent(".claude.json")

        let cursor = MCPClient(
            id: "cursor",
            name: "Cursor",
            blurb: "Adds Kommando to Cursor (opens Cursor to confirm).",
            symbol: "cursorarrow.rays",
            isInstalled: appInstalled("Cursor") || onPath("cursor"),
            isConfigured: configHasServer(cursorConfig),
            primary: cursorDeeplink(helperPath: helperPath).map { .deeplink($0) } ?? .manual,
            copyText: clientConfigJSON(helperPath: helperPath),
            copyHint: "Add to ~/.cursor/mcp.json"
        )

        let vscode = MCPClient(
            id: "vscode",
            name: "VS Code",
            blurb: "Registers Kommando with VS Code's MCP support.",
            symbol: "chevron.left.forwardslash.chevron.right",
            isInstalled: appInstalled("Visual Studio Code") || onPath("code"),
            isConfigured: configHasServer(vscodeConfig),
            primary: .shell(
                command: "code --add-mcp \(shellQuote(vscodeConfigJSON(helperPath: helperPath)))",
                display: "code --add-mcp '…'"
            ),
            copyText: "code --add-mcp '\(vscodeConfigJSON(helperPath: helperPath))'",
            copyHint: "Run in a terminal where the `code` command is installed"
        )

        let claudeDesktop = MCPClient(
            id: "claude-desktop",
            name: "Claude Desktop",
            blurb: "Writes Kommando into Claude Desktop's config. Restart Claude afterwards.",
            symbol: "sparkles",
            isInstalled: appInstalled("Claude"),
            isConfigured: configHasServer(claudeDesktopConfigURL),
            primary: .writeJSON(path: claudeDesktopConfigURL),
            copyText: clientConfigJSON(helperPath: helperPath),
            copyHint: "Add to \(claudeDesktopConfigURL.path)"
        )

        let claudeCode = MCPClient(
            id: "claude-code",
            name: "Claude Code",
            blurb: "Adds Kommando for all your projects via the Claude CLI.",
            symbol: "terminal",
            isInstalled: clis.claude,
            isConfigured: configHasServer(claudeCodeConfig),
            primary: .shell(
                command: "claude mcp add -s user \(serverName) -- \(q)",
                display: "claude mcp add -s user kommando -- …"
            ),
            copyText: "claude mcp add -s user \(serverName) -- \(q)",
            copyHint: "Run in a terminal where the `claude` command is installed"
        )

        let codex = MCPClient(
            id: "codex",
            name: "Codex CLI",
            blurb: "Add the snippet to Codex's config file, then restart Codex.",
            symbol: "chevron.left.slash.chevron.right",
            isInstalled: clis.codex,
            isConfigured: configHasServer(codexConfig),
            primary: .manual,
            copyText: codexConfigTOML(helperPath: helperPath),
            copyHint: "Add to ~/.codex/config.toml"
        )

        return [cursor, vscode, claudeDesktop, claudeCode, codex]
    }

    // MARK: - Detection helpers

    /// True when an app bundle of this name exists in a standard Applications folder.
    private static func appInstalled(_ name: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/\(name).app")
            || fm.fileExists(atPath: NSHomeDirectory() + "/Applications/\(name).app")
    }

    /// True when a command resolves on the login-shell PATH. Cheap synchronous check used for
    /// the CLIs that double as GUI apps (cursor/code); the slower combined probe is `probeCLIs`.
    private static func onPath(_ command: String) -> Bool {
        for dir in ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"] {
            if FileManager.default.isExecutableFile(atPath: "\(dir)/\(command)") {
                return true
            }
        }
        return false
    }

    /// Probes the CLIs that only live on the user's PATH (claude, codex). Runs a single login
    /// shell so user-customised PATHs are respected.
    nonisolated static func probeCLIs() -> MCPDetectedCLIs {
        let output = (try? runLoginShell(
            "command -v claude >/dev/null 2>&1 && echo claude; command -v codex >/dev/null 2>&1 && echo codex"
        )) ?? ""
        var result = MCPDetectedCLIs()
        result.claude = output.contains("claude")
        result.codex = output.contains("codex")
        return result
    }

    /// True when a JSON/TOML config already references our server under an mcpServers key.
    /// Best-effort: a match means "already added"; a miss just shows the Add button (re-adding
    /// is idempotent), so false negatives are harmless.
    private static func configHasServer(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        // Matches the JSON key ("kommando") and the TOML table ([mcp_servers.kommando]); plain
        // project paths like ".../Kommando" don't contain the lowercased quoted key.
        return text.contains("\"\(serverName)\"") || text.contains("mcp_servers.\(serverName)")
    }

    // MARK: - Config snippets

    /// The minimal `mcpServers` block most JSON-based clients accept verbatim.
    static func clientConfigJSON(helperPath: String) -> String {
        """
        {
          "mcpServers": {
            "\(serverName)": {
              "command": "\(jsonEscape(helperPath))"
            }
          }
        }
        """
    }

    /// VS Code's `--add-mcp` wants the single-server object inline (with a name).
    static func vscodeConfigJSON(helperPath: String) -> String {
        "{\"name\":\"\(serverName)\",\"command\":\"\(jsonEscape(helperPath))\"}"
    }

    static func codexConfigTOML(helperPath: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = "\(jsonEscape(helperPath))"
        """
    }

    // MARK: - Deeplinks

    static func cursorDeeplink(helperPath: String) -> URL? {
        let inner = ["command": helperPath]
        guard let data = try? JSONSerialization.data(withJSONObject: inner) else { return nil }
        let base64 = data.base64EncodedString()
        // Cursor reads `config` as base64; `+`, `/`, `=` must all be percent-encoded so the
        // query survives intact (a literal `+` would otherwise decode to a space).
        let encoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/mcp/install"
        components.percentEncodedQuery = "name=\(serverName)&config=\(encoded)"
        return components.url
    }

    // MARK: - Actions

    /// Runs an install action that can complete on its own. Returns a short status line.
    /// Throws `MCPInstallError` (or rethrows IO errors) on failure.
    nonisolated static func run(_ action: MCPClient.Action) throws -> String {
        switch action {
        case let .deeplink(url):
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return "Opened the client to finish installing."
        case let .shell(command, _):
            let output = try runLoginShell(command)
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Added Kommando." : trimmed
        case let .writeJSON(path):
            try mergeMCPServer(into: path)
            return "Updated \(path.lastPathComponent). Restart the client to load it."
        case .manual:
            return ""
        }
    }

    private nonisolated static func runLoginShell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw MCPInstallError.shellFailed(code: process.terminationStatus, output: output)
        }
        return output
    }

    /// Reads (or creates) a JSON config file and merges our server entry under `mcpServers`,
    /// preserving any other servers already configured.
    private nonisolated static func mergeMCPServer(into url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": MCPPaths.helperPath]
        root["mcpServers"] = servers

        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try out.write(to: url, options: .atomic)
    }

    // MARK: - Paths & escaping

    static var claudeDesktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    private static func jsonEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
