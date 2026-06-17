//
//  AIChatService.swift
//  Kommando
//
//  Streaming chat with tool-use for the AI sidebar. Drives a single assistant "turn":
//  streams text deltas via `onEvent`, accumulates any tool calls, and returns them so
//  the caller can execute tools and continue the loop. Supports Anthropic and OpenAI.
//

import Foundation

struct ToolUse {
    let id: String
    let name: String
    let input: [String: Any]
}

struct AssistantTurn {
    var text: String
    var toolUses: [ToolUse]
}

enum AIStreamEvent {
    case text(String)
    case toolUseStarted(id: String, name: String)
}

@MainActor
enum AIChatService {
    private static let maxTokens = 2048

    static func streamTurn(
        provider: AIProvider,
        key: String,
        system: String,
        tools: [AIToolKind],
        history: [ChatMessage],
        onEvent: @escaping (AIStreamEvent) -> Void
    ) async throws -> AssistantTurn {
        switch provider {
        case .anthropic:
            return try await streamAnthropic(key: key, system: system, tools: tools, history: history, onEvent: onEvent)
        case .openai:
            return try await streamOpenAI(key: key, system: system, tools: tools, history: history, onEvent: onEvent)
        }
    }

    // MARK: - Anthropic

    private static func streamAnthropic(
        key: String,
        system: String,
        tools: [AIToolKind],
        history: [ChatMessage],
        onEvent: @escaping (AIStreamEvent) -> Void
    ) async throws -> AssistantTurn {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": AIModels.anthropic,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "tools": tools.map { ["name": $0.toolName, "description": $0.description, "input_schema": $0.inputSchema] },
            "messages": anthropicMessages(from: history),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await throwIfErrorStatus(response, bytes: bytes)

        var text = ""
        // index -> (id, name, partial json)
        var toolBuffers: [Int: (id: String, name: String, json: String)] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let obj = sseObject(from: line) else { continue }
            switch obj["type"] as? String {
            case "content_block_start":
                let index = obj["index"] as? Int ?? 0
                if let block = obj["content_block"] as? [String: Any],
                   (block["type"] as? String) == "tool_use" {
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? ""
                    toolBuffers[index] = (id, name, "")
                    onEvent(.toolUseStarted(id: id, name: name))
                }
            case "content_block_delta":
                let index = obj["index"] as? Int ?? 0
                guard let delta = obj["delta"] as? [String: Any] else { break }
                switch delta["type"] as? String {
                case "text_delta":
                    let t = delta["text"] as? String ?? ""
                    text += t
                    onEvent(.text(t))
                case "input_json_delta":
                    toolBuffers[index]?.json += (delta["partial_json"] as? String ?? "")
                default:
                    break
                }
            case "message_stop":
                break
            default:
                break
            }
        }

        let toolUses = toolBuffers.keys.sorted().compactMap { key -> ToolUse? in
            guard let buf = toolBuffers[key] else { return nil }
            return ToolUse(id: buf.id, name: buf.name, input: parseObject(buf.json))
        }
        return AssistantTurn(text: text, toolUses: toolUses)
    }

    private static func anthropicMessages(from history: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for msg in history where !msg.isEmpty {
            switch msg.role {
            case .user:
                out.append(["role": "user", "content": msg.text])
            case .assistant:
                var content: [[String: Any]] = []
                if !msg.text.isEmpty {
                    content.append(["type": "text", "text": msg.text])
                }
                for call in msg.toolCalls {
                    content.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": parseObject(call.inputJSON),
                    ])
                }
                if !content.isEmpty {
                    out.append(["role": "assistant", "content": content])
                }
                if !msg.toolCalls.isEmpty {
                    let results: [[String: Any]] = msg.toolCalls.map { call in
                        [
                            "type": "tool_result",
                            "tool_use_id": call.id,
                            "content": call.result ?? "",
                        ]
                    }
                    out.append(["role": "user", "content": results])
                }
            }
        }
        return out
    }

    // MARK: - OpenAI

    private static func streamOpenAI(
        key: String,
        system: String,
        tools: [AIToolKind],
        history: [ChatMessage],
        onEvent: @escaping (AIStreamEvent) -> Void
    ) async throws -> AssistantTurn {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": AIModels.openai,
            "max_tokens": maxTokens,
            "stream": true,
            "tools": tools.map {
                ["type": "function", "function": ["name": $0.toolName, "description": $0.description, "parameters": $0.inputSchema]]
            },
            "messages": openAIMessages(system: system, history: history),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await throwIfErrorStatus(response, bytes: bytes)

        var text = ""
        var toolBuffers: [Int: (id: String, name: String, args: String)] = [:]
        var started: Set<Int> = []

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (obj["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                text += content
                onEvent(.text(content))
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let index = call["index"] as? Int ?? 0
                    if toolBuffers[index] == nil { toolBuffers[index] = ("", "", "") }
                    if let id = call["id"] as? String, !id.isEmpty { toolBuffers[index]?.id = id }
                    if let fn = call["function"] as? [String: Any] {
                        if let name = fn["name"] as? String, !name.isEmpty {
                            toolBuffers[index]?.name = name
                            if !started.contains(index) {
                                started.insert(index)
                                onEvent(.toolUseStarted(id: toolBuffers[index]?.id ?? "", name: name))
                            }
                        }
                        if let args = fn["arguments"] as? String { toolBuffers[index]?.args += args }
                    }
                }
            }
        }

        let toolUses = toolBuffers.keys.sorted().compactMap { key -> ToolUse? in
            guard let buf = toolBuffers[key], !buf.name.isEmpty else { return nil }
            let id = buf.id.isEmpty ? UUID().uuidString : buf.id
            return ToolUse(id: id, name: buf.name, input: parseObject(buf.args))
        }
        return AssistantTurn(text: text, toolUses: toolUses)
    }

    private static func openAIMessages(system: String, history: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for msg in history where !msg.isEmpty {
            switch msg.role {
            case .user:
                out.append(["role": "user", "content": msg.text])
            case .assistant:
                var assistant: [String: Any] = ["role": "assistant"]
                assistant["content"] = msg.text.isEmpty ? NSNull() : msg.text
                if !msg.toolCalls.isEmpty {
                    assistant["tool_calls"] = msg.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.inputJSON.isEmpty ? "{}" : call.inputJSON],
                        ]
                    }
                }
                out.append(assistant)
                for call in msg.toolCalls {
                    out.append(["role": "tool", "tool_call_id": call.id, "content": call.result ?? ""])
                }
            }
        }
        return out
    }

    // MARK: - Helpers

    private static func sseObject(from line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parseObject(_ json: String) -> [String: Any] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func throwIfErrorStatus(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) else { return }
        var body = ""
        for try await line in bytes.lines {
            body += line + "\n"
            if body.count > 2000 { break }
        }
        throw AIError.http(http.statusCode, body)
    }
}
