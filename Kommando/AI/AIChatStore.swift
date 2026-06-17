//
//  AIChatStore.swift
//  Kommando
//
//  Per-window store for the AI sidebar: holds the list of conversations, the sidebar's
//  open/closed state, and orchestrates the streaming tool-use loop. Tab context and tool
//  execution are injected by AppModel so the assistant can see and act on the focused pane.
//

import Foundation

@MainActor
@Observable
final class AIChatStore {
    var chats: [AIChat] = []
    var activeChatId: String = ""
    var sidebarVisible = false
    var isStreaming = false
    var errorMessage: String?
    /// When on, commands the assistant generates are executed in the terminal, not just inserted.
    var autoExecute = false

    /// Supplies the latest focused-tab context (injected by AppModel).
    var contextProvider: (() -> TabContext?)?
    /// Executes a tool call and returns its textual result (injected by AppModel).
    var toolExecutor: ((String, [String: Any]) async -> String)?

    private var streamTask: Task<Void, Never>?
    private let maxToolIterations = 6

    init() {
        newChat()
    }

    var activeChat: AIChat? {
        chats.first { $0.id == activeChatId }
    }

    var hasAPIKey: Bool {
        let settings = SettingsStore.shared
        return !(settings.apiKey(for: settings.aiProvider) ?? "").isEmpty
    }

    // MARK: - Sidebar / chat management

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    func newChat() {
        // Reuse the current chat if it's still empty so we don't pile up blank chats.
        if let active = activeChat, active.isPristine {
            return
        }
        let chat = AIChat()
        chats.insert(chat, at: 0)
        activeChatId = chat.id
    }

    func selectChat(_ id: String) {
        activeChatId = id
    }

    func deleteChat(_ id: String) {
        chats.removeAll { $0.id == id }
        if chats.isEmpty {
            newChat()
        } else if activeChatId == id {
            activeChatId = chats[0].id
        }
    }

    // MARK: - Sending

    func send(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, let chat = activeChat else { return }
        errorMessage = nil

        let userMessage = ChatMessage(role: .user, text: trimmed)
        chat.messages.append(userMessage)
        if chat.isPristine == false, chat.title == "New Chat" {
            chat.title = String(trimmed.prefix(48))
        }

        isStreaming = true
        streamTask = Task { [weak self] in
            await self?.runLoop(chat: chat)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if let last = activeChat?.messages.last, last.role == .assistant {
            last.isStreaming = false
        }
    }

    private func runLoop(chat: AIChat) async {
        defer {
            isStreaming = false
            if let last = chat.messages.last, last.role == .assistant {
                last.isStreaming = false
            }
        }

        let settings = SettingsStore.shared
        let provider = settings.aiProvider
        guard let key = settings.apiKey(for: provider), !key.isEmpty else {
            errorMessage = AIError.noKey(provider).localizedDescription
            return
        }

        do {
            var iterations = 0
            while iterations < maxToolIterations {
                iterations += 1
                try Task.checkCancellation()

                let history = chat.messages
                let assistant = ChatMessage(role: .assistant, isStreaming: true)
                chat.messages.append(assistant)

                let turn = try await AIChatService.streamTurn(
                    provider: provider,
                    key: key,
                    system: buildSystemPrompt(),
                    tools: AIToolKind.allCases,
                    history: history
                ) { event in
                    switch event {
                    case .text(let delta):
                        assistant.text += delta
                    case .toolUseStarted(let id, let name):
                        if !assistant.toolCalls.contains(where: { $0.id == id }) {
                            assistant.toolCalls.append(ToolCallRecord(id: id, name: name, inputJSON: ""))
                        }
                    }
                }

                assistant.text = turn.text
                assistant.toolCalls = turn.toolUses.map { use in
                    let record = assistant.toolCalls.first { $0.id == use.id }
                        ?? ToolCallRecord(id: use.id, name: use.name, inputJSON: "")
                    record.inputJSON = prettyJSON(use.input)
                    record.isRunning = true
                    return record
                }
                assistant.isStreaming = false

                if turn.toolUses.isEmpty {
                    break
                }

                for use in turn.toolUses {
                    try Task.checkCancellation()
                    let result = await toolExecutor?(use.name, use.input) ?? "Tool unavailable."
                    if let record = assistant.toolCalls.first(where: { $0.id == use.id }) {
                        record.result = result
                        record.isRunning = false
                    }
                }
            }
        } catch is CancellationError {
            // Stopped by the user; leave partial output in place.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildSystemPrompt() -> String {
        var prompt = AIChatPrompts.system
        if autoExecute {
            prompt += "\n\nAuto-run is ENABLED: commands you pass to `insert_command` are executed "
                + "immediately in the user's terminal. Only run commands that are safe and clearly "
                + "intended; ask first before anything destructive or irreversible."
        }
        if let context = contextProvider?() {
            prompt += "\n\n# Current tab context\n"
            prompt += "Tab: \(context.tabTitle)\n"
            prompt += "Shell: \(context.shell)\n"
            prompt += "Working directory: \(context.cwd ?? "unknown")\n"
            if !context.output.isEmpty {
                prompt += "\nVisible terminal output (most recent lines):\n```\n\(context.output)\n```"
            }
        }
        return prompt
    }

    private func prettyJSON(_ object: [String: Any]) -> String {
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
