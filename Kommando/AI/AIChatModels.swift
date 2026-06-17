//
//  AIChatModels.swift
//  Kommando
//
//  Observable models backing the AI sidebar: conversations, messages, and the tool
//  calls the assistant makes during a turn. Reference types so streaming deltas update
//  the UI in place.
//

import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

/// A single tool invocation the assistant requested during a turn. `result` is filled
/// in once we've executed the tool locally and is fed back to the model.
@MainActor
@Observable
final class ToolCallRecord: Identifiable {
    let id: String
    let name: String
    var inputJSON: String
    var result: String?
    var isRunning: Bool

    init(id: String, name: String, inputJSON: String, result: String? = nil, isRunning: Bool = true) {
        self.id = id
        self.name = name
        self.inputJSON = inputJSON
        self.result = result
        self.isRunning = isRunning
    }

    /// Human-readable label, e.g. "read_terminal_output" → "Read terminal output".
    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }
}

@MainActor
@Observable
final class ChatMessage: Identifiable {
    let id = UUID().uuidString
    let role: ChatRole
    var text: String
    var toolCalls: [ToolCallRecord]
    var isStreaming: Bool
    let createdAt = Date()

    init(role: ChatRole, text: String = "", toolCalls: [ToolCallRecord] = [], isStreaming: Bool = false) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.isStreaming = isStreaming
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && toolCalls.isEmpty
    }
}

@MainActor
@Observable
final class AIChat: Identifiable {
    let id = UUID().uuidString
    var title: String
    var messages: [ChatMessage] = []
    let createdAt = Date()

    init(title: String = "New Chat") {
        self.title = title
    }

    var isPristine: Bool {
        messages.allSatisfy { $0.role != .user }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
