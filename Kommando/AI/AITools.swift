//
//  AITools.swift
//  Kommando
//
//  Tools the AI sidebar can call, plus the live context (cwd / output) captured from
//  the focused terminal pane. Both providers receive the same tool set; the service
//  serializes the schema into each provider's wire format.
//

import Foundation

/// A snapshot of the currently focused tab, injected into the system prompt so the
/// assistant always has context about what the user is looking at.
struct TabContext {
    let tabTitle: String
    let cwd: String?
    let shell: String
    let output: String
}

enum AIToolKind: String, CaseIterable {
    case readTerminalOutput = "read_terminal_output"
    case insertCommand = "insert_command"

    var toolName: String { rawValue }

    var description: String {
        switch self {
        case .readTerminalOutput:
            return "Read the current visible output of the user's focused terminal pane. "
                + "Use this when the user asks about what's on screen, errors, or command output."
        case .insertCommand:
            return "Insert a shell command into the user's focused terminal WITHOUT running it, "
                + "so they can review and press Enter. Use when the user asks you to run or write a command."
        }
    }

    /// JSON Schema for the tool's input (shared by Anthropic `input_schema` and
    /// OpenAI `function.parameters`).
    var inputSchema: [String: Any] {
        switch self {
        case .readTerminalOutput:
            return [
                "type": "object",
                "properties": [:],
            ]
        case .insertCommand:
            return [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "description": "The shell command to insert into the terminal.",
                    ],
                ],
                "required": ["command"],
            ]
        }
    }
}

enum AIChatPrompts {
    static let system = """
    You are Kommando's built-in AI assistant, embedded in a native macOS terminal app.
    You help the user with their shell, command-line tasks, and understanding terminal output.

    Guidelines:
    - Be concise and practical. Prefer short answers and copy-pasteable commands.
    - You are given the current tab's working directory and visible output as context.
    - When the user asks for a command, you can use the `insert_command` tool to place it
      in their terminal (it is never auto-executed — they review and run it).
    - Use `read_terminal_output` when you need the latest on-screen output to answer.
    - Target macOS zsh and BSD coreutils. Format code and commands in fenced code blocks.
    - If something is destructive, call it out before suggesting it.
    """
}
