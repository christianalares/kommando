//
//  Entry.swift
//  kommando-mcp
//
//  The MCP server (stdio) that external AI tools spawn. It exposes Kommando's terminals as
//  MCP tools and relays each call to the app's local control socket. Every tool takes an
//  optional `id` (a session id from `list_terminals`) so the model can pick exactly which
//  pane to operate on; omitting it targets the focused pane of the current window.
//

import Foundation
import MCP

@main
struct KommandoMCP {
    static func main() async throws {
        let server = Server(
            name: "kommando",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            handle(params)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool catalog

    /// A JSON Schema string property: `{"type": "...", "description": "..."}`.
    private static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    /// A JSON Schema object: `{"type":"object","properties":{…},"required":[…]}`.
    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        return .object(object)
    }

    static var tools: [Tool] {
        [
            Tool(
                name: "list_terminals",
                description: """
                List every open terminal/inspector session across all Kommando windows. \
                Returns each session's id, title, current working directory, busy state, tab \
                name, window number, and whether it's the focused pane. Use the id with the \
                other tools to target a specific session.
                """,
                inputSchema: schema([:]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "read_terminal",
                description: """
                Read the visible output of a terminal session. Pass `id` to choose a session \
                (from list_terminals); omit it to read the focused pane.
                """,
                inputSchema: schema([
                    "id": prop("string", "Session id to read (optional; defaults to the focused pane)"),
                    "lines": prop("integer", "Maximum number of lines to return (optional, default 50)")
                ]),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "write_terminal",
                description: """
                Type text into a terminal session. By default it runs the text as a command \
                (a newline is appended); set `execute` to false to insert without running. \
                Pass `id` to target a session; omit it for the focused pane. After running a \
                command, use read_terminal to inspect the result.
                """,
                inputSchema: schema([
                    "text": prop("string", "The command or text to send"),
                    "id": prop("string", "Session id to target (optional; defaults to the focused pane)"),
                    "execute": prop("boolean", "Whether to run the text as a command (default true)")
                ], required: ["text"])
            ),
            Tool(
                name: "send_control",
                description: """
                Send a control character to a terminal session, e.g. \"C\" for Ctrl-C to \
                interrupt, \"D\" for Ctrl-D, \"Z\" to suspend. Pass `id` to target a session; \
                omit it for the focused pane.
                """,
                inputSchema: schema([
                    "letter": prop("string", "The control letter, e.g. C for Ctrl-C"),
                    "id": prop("string", "Session id to target (optional; defaults to the focused pane)")
                ], required: ["letter"])
            ),
            Tool(
                name: "create_terminal",
                description: """
                Open a new terminal tab in the current window and return its session id. Set \
                `inspector` to true to open an inspector (REPL) tab instead. To split the \
                current view instead of opening a tab, use split_pane.
                """,
                inputSchema: schema([
                    "inspector": prop("boolean", "Open an inspector tab instead of a terminal (default false)")
                ])
            ),
            Tool(
                name: "split_pane",
                description: """
                Split a pane to create a new terminal alongside an existing one in the same tab, \
                and return the new pane's session id. Ideal for running a task in its own pane \
                next to the user's work. Pass `id` to choose which pane to split (from \
                list_terminals); omit it to split the focused pane. The new terminal inherits \
                the working directory of the pane it was split from.
                """,
                inputSchema: schema([
                    "id": prop("string", "Session id of the pane to split (optional; defaults to the focused pane)"),
                    "direction": prop("string", "\"vertical\" stacks top/bottom, \"horizontal\" places side by side (default vertical)"),
                    "inspector": prop("boolean", "Make the new pane an inspector (REPL) instead of a terminal (default false)")
                ])
            ),
            Tool(
                name: "focus_terminal",
                description: "Bring a session's window/tab to the front and focus its pane.",
                inputSchema: schema([
                    "id": prop("string", "Session id to focus")
                ], required: ["id"]),
                annotations: .init(destructiveHint: false)
            ),
            Tool(
                name: "close_terminal",
                description: "Close a session's pane (cascading to its tab/window if it was the last one).",
                inputSchema: schema([
                    "id": prop("string", "Session id to close")
                ], required: ["id"]),
                annotations: .init(destructiveHint: true)
            )
        ]
    }

    // MARK: - Dispatch

    static func handle(_ params: CallTool.Parameters) -> CallTool.Result {
        let args = params.arguments
        let id = args?["id"]?.stringValue

        switch params.name {
        case "list_terminals":
            let response = SocketClient.request(["op": "list"])
            guard response["ok"] as? Bool == true else { return failure(response) }
            let sessions = response["sessions"] as? [[String: Any]] ?? []
            if sessions.isEmpty {
                return text("(no terminal sessions are open)")
            }
            let pretty = (try? JSONSerialization.data(withJSONObject: sessions, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return text(pretty)

        case "read_terminal":
            var payload: [String: Any] = ["op": "read"]
            if let id { payload["id"] = id }
            if let lines = intArg(args?["lines"]) { payload["lines"] = lines }
            let response = SocketClient.request(payload)
            guard response["ok"] as? Bool == true else { return failure(response) }
            return text(response["text"] as? String ?? "")

        case "write_terminal":
            guard let textValue = args?["text"]?.stringValue else {
                return error("Missing required 'text' argument.")
            }
            let execute = boolArg(args?["execute"]) ?? true
            var payload: [String: Any] = ["op": "write", "text": textValue, "execute": execute]
            if let id { payload["id"] = id }
            let response = SocketClient.request(payload)
            guard response["ok"] as? Bool == true else { return failure(response) }
            let target = response["id"] as? String ?? "the focused pane"
            return text(execute
                ? "Ran in session \(target). Use read_terminal to see the output."
                : "Inserted into session \(target) without executing.")

        case "send_control":
            guard let letter = args?["letter"]?.stringValue else {
                return error("Missing required 'letter' argument.")
            }
            var payload: [String: Any] = ["op": "control", "letter": letter]
            if let id { payload["id"] = id }
            let response = SocketClient.request(payload)
            guard response["ok"] as? Bool == true else { return failure(response) }
            return text("Sent Ctrl-\(letter.uppercased()) to session \(response["id"] as? String ?? "the focused pane").")

        case "create_terminal":
            let inspector = boolArg(args?["inspector"]) ?? false
            let response = SocketClient.request(["op": "create", "inspector": inspector])
            guard response["ok"] as? Bool == true else { return failure(response) }
            return text("Created session \(response["id"] as? String ?? "(unknown)").")

        case "split_pane":
            let inspector = boolArg(args?["inspector"]) ?? false
            let direction = args?["direction"]?.stringValue ?? "vertical"
            var payload: [String: Any] = ["op": "split", "inspector": inspector, "direction": direction]
            if let id { payload["id"] = id }
            let response = SocketClient.request(payload)
            guard response["ok"] as? Bool == true else { return failure(response) }
            return text("Split into new session \(response["id"] as? String ?? "(unknown)"). Use write_terminal with this id to run a task in it.")

        case "focus_terminal":
            guard let id else { return error("Missing required 'id' argument.") }
            let response = SocketClient.request(["op": "focus", "id": id])
            guard response["ok"] as? Bool == true else { return failure(response) }
            return text("Focused session \(id).")

        case "close_terminal":
            guard let id else { return error("Missing required 'id' argument.") }
            let response = SocketClient.request(["op": "close", "id": id])
            guard response["ok"] as? Bool == true else { return failure(response) }
            return text("Closed session \(id).")

        default:
            return error("Unknown tool: \(params.name)")
        }
    }

    // MARK: - Helpers

    private static func intArg(_ value: Value?) -> Int? {
        if let i = value?.intValue { return i }
        if let s = value?.stringValue { return Int(s) }
        return nil
    }

    private static func boolArg(_ value: Value?) -> Bool? {
        if let b = value?.boolValue { return b }
        if let s = value?.stringValue { return Bool(s.lowercased()) }
        return nil
    }

    private static func text(_ string: String) -> CallTool.Result {
        .init(content: [.text(text: string, annotations: nil, _meta: nil)], isError: false)
    }

    private static func error(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func failure(_ response: [String: Any]) -> CallTool.Result {
        error(response["error"] as? String ?? "Kommando returned an error.")
    }
}
