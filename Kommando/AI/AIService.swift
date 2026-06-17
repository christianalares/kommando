//
//  AIService.swift
//  Kommando
//
//  Talks to Anthropic / OpenAI for shell command generation and REPL inspector JS.
//  System prompts and request shapes are ported verbatim from the Glaze build.
//

import Foundation

enum AIModels {
    static let anthropic = "claude-haiku-4-5"
    static let openai = "gpt-4o-mini"
}

enum AIError: LocalizedError {
    case noKey(AIProvider)
    case http(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noKey(let provider):
            return "No API key set for \(provider.displayName). Open Settings (⌘,) to add one."
        case .http(let status, let body):
            return "API error \(status): \(body.prefix(200))"
        case .malformedResponse:
            return "Unexpected response from the AI provider."
        }
    }
}

@MainActor
enum AIService {
    private static let commandSystemPrompt = """
    You generate a single macOS zsh shell command for the user's request.
    Rules:
    - Output ONLY the shell command, no markdown, no backticks, no explanation, no leading shell prefix.
    - Never include "$" or "#" prefixes.
    - Prefer concise, idiomatic one-liners that work on macOS (BSD coreutils, pbcopy, pbpaste, open, etc.).
    - If multiple steps are needed, chain with &&, |, or ;.
    - Do not include trailing newlines.
    - If the request is unclear or unsafe, output: echo "Unclear request"
    """

    private static let inspectorSystemPrompt = """
    You write JavaScript to answer the user's question about a value already bound to $0 in a REPL.

    Output rules:
    - Output ONLY JavaScript. No markdown fences, no comments, no explanation.
    - Prefer a single expression — its result becomes the displayed answer.
    - Use $0 to refer to the current captured value. $1, $2, … are older captures.
    - For filtering: array methods like .filter / .find / .some / .map.
    - For aggregation: .reduce, .length, Math methods.
    - Do NOT call console.log — the REPL displays the value of the last expression.
    - Keep it concise. One line if possible, up to ~5 lines.
    - If the question can't be answered from $0, return: "Cannot answer from $0"
    """

    static func generateCommand(prompt: String, cwd: String?, shell: String) async throws -> String {
        let userMessage = """
        Shell: \(shell)
        Working directory: \(cwd ?? "~")
        Request: \(prompt)
        """
        let raw = try await complete(system: commandSystemPrompt, user: userMessage, maxTokens: 256)
        return sanitizeCommand(raw)
    }

    static func askInspectorJS(prompt: String, dataPreview: String) async throws -> String {
        let userMessage = """
        The value at $0 is (inspect format, may be truncated):

        ```
        \(dataPreview)
        ```

        Question: \(prompt)
        """
        let raw = try await complete(system: inspectorSystemPrompt, user: userMessage, maxTokens: 512)
        return stripCodeFences(raw)
    }

    // MARK: - Provider routing

    private static func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let settings = SettingsStore.shared
        let provider = settings.aiProvider
        guard let key = settings.apiKey(for: provider), !key.isEmpty else {
            throw AIError.noKey(provider)
        }
        switch provider {
        case .anthropic:
            return try await callAnthropic(key: key, system: system, user: user, maxTokens: maxTokens)
        case .openai:
            return try await callOpenAI(key: key, system: system, user: user, maxTokens: maxTokens)
        }
    }

    private static func callAnthropic(key: String, system: String, user: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": AIModels.anthropic,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw AIError.malformedResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func callOpenAI(key: String, system: String, user: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": AIModels.openai,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIError.malformedResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            throw AIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Output cleanup (ports the Glaze sanitize / stripCodeFences helpers)

    private static func sanitizeCommand(_ raw: String) -> String {
        var cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cmd = cmd.replacing(/^```(?:bash|sh|zsh)?\s*\n?/, with: "")
        cmd = cmd.replacing(/\n?```\s*$/, with: "")
        cmd = cmd.replacing(/^[$#>]\s+/, with: "")
        cmd = cmd
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " && ")
        return cmd
    }

    private static func stripCodeFences(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacing(/^```(?:javascript|js|ts|typescript)?\s*\n?/, with: "")
        s = s.replacing(/\n?```\s*$/, with: "")
        s = s.replacing(/^(?:javascript|js)\s*\n/.ignoresCase(), with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
