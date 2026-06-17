//
//  ReplSession.swift
//  Kommando
//
//  A JavaScriptCore-backed REPL. Mirrors the Glaze inspector tab: a persistent JS
//  context, console interception, top-level const/let rewritten to var so bindings
//  persist across evaluations, and $0/$1/… captures of recent results.
//

import Foundation
import JavaScriptCore

struct ReplLog: Identifiable {
    enum Level: String {
        case log, info, warn, error
    }
    let id = UUID()
    let level: Level
    let text: String
    let value: JSONValue?
}

enum ReplResult {
    case value(text: String, json: JSONValue?)
    case error(String)
    case undefined
}

struct ReplEntry: Identifiable {
    let id = UUID()
    let input: String
    let isAIGenerated: Bool
    let logs: [ReplLog]
    let result: ReplResult
}

@MainActor
@Observable
final class ReplSession: Identifiable {
    let id: String
    var entries: [ReplEntry] = []

    private let context: JSContext
    private var captures: [JSValue] = []
    private var pendingLogs: [ReplLog] = []

    init(id: String) {
        self.id = id
        context = JSContext()
        setupConsole()
    }

    var currentCapturePreview: String {
        guard let zero = captures.first else { return "undefined" }
        return describe(zero, pretty: true)
    }

    // MARK: - Evaluation

    func evaluate(_ input: String, isAIGenerated: Bool = false) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pendingLogs = []
        context.exception = nil

        let code = Self.rewriteTopLevelDeclarations(trimmed)
        let result = context.evaluateScript(code)
        let logs = pendingLogs

        if let exception = context.exception {
            entries.append(ReplEntry(input: trimmed, isAIGenerated: isAIGenerated, logs: logs,
                                     result: .error(exception.toString() ?? "Error")))
            context.exception = nil
            return
        }

        guard let result, !result.isUndefined else {
            entries.append(ReplEntry(input: trimmed, isAIGenerated: isAIGenerated, logs: logs, result: .undefined))
            return
        }

        capture(result)
        let json = jsonValue(from: result)
        entries.append(ReplEntry(input: trimmed, isAIGenerated: isAIGenerated, logs: logs,
                                 result: .value(text: describe(result, pretty: false), json: json)))
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - Captures ($0, $1, …)

    private func capture(_ value: JSValue) {
        captures.insert(value, at: 0)
        if captures.count > 10 {
            captures.removeLast()
        }
        for (index, capture) in captures.enumerated() {
            context.setObject(capture, forKeyedSubscript: "$\(index)" as NSString)
        }
    }

    // MARK: - Console interception

    private func setupConsole() {
        guard let console = JSValue(newObjectIn: context) else { return }
        for level in [ReplLog.Level.log, .info, .warn, .error] {
            let handler: @convention(block) () -> Void = { [weak self] in
                guard let self else { return }
                let args = (JSContext.currentArguments() as? [JSValue]) ?? []
                self.appendLog(level: level, args: args)
            }
            console.setObject(handler, forKeyedSubscript: level.rawValue as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private func appendLog(level: ReplLog.Level, args: [JSValue]) {
        let text = args.map { describe($0, pretty: false) }.joined(separator: " ")
        let value = args.count == 1 ? jsonValue(from: args[0]) : nil
        pendingLogs.append(ReplLog(level: level, text: text, value: value))
    }

    // MARK: - JSValue helpers

    private func jsonValue(from value: JSValue) -> JSONValue? {
        guard value.isObject || value.isArray else { return nil }
        guard let json = context.objectForKeyedSubscript("JSON"),
              let stringify = json.objectForKeyedSubscript("stringify"),
              let stringified = stringify.call(withArguments: [value]),
              !stringified.isUndefined, !stringified.isNull,
              let text = stringified.toString(),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return JSONValue(object)
    }

    private func describe(_ value: JSValue, pretty: Bool) -> String {
        if value.isUndefined { return "undefined" }
        if value.isNull { return "null" }
        if value.isString { return "\"\(value.toString() ?? "")\"" }

        if value.isObject || value.isArray {
            if let json = context.objectForKeyedSubscript("JSON"),
               let stringify = json.objectForKeyedSubscript("stringify") {
                let args: [Any] = pretty ? [value, NSNull(), 2] : [value]
                if let stringified = stringify.call(withArguments: args),
                   !stringified.isUndefined,
                   let text = stringified.toString() {
                    return text
                }
            }
        }
        return value.toString() ?? "undefined"
    }

    // MARK: - Const/let → var rewrite (matches the Glaze REPL behavior)

    private static let declarationRegex = try! NSRegularExpression(pattern: "(?m)^([ \\t]*)(?:const|let)\\b")

    static func rewriteTopLevelDeclarations(_ code: String) -> String {
        let range = NSRange(code.startIndex..., in: code)
        return declarationRegex.stringByReplacingMatches(in: code, range: range, withTemplate: "$1var")
    }
}
