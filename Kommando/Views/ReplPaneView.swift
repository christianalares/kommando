//
//  ReplPaneView.swift
//  Kommando
//
//  The Inspector (JS REPL) pane: a transcript of evaluations with expandable value
//  output, a JS input line, and an AI "ask about $0" line.
//

import SwiftUI

struct ReplPaneView: View {
    let session: ReplSession

    @State private var input = ""
    @State private var aiInput = ""
    @State private var aiLoading = false
    @State private var aiError: String?

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            aiRow
            Divider()
            inputRow
        }
        .background(Color.black.opacity(0.18))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.entries.isEmpty {
                        Text("JavaScript Inspector — evaluate expressions, inspect results, and use ⌃↩-style AI on $0.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    ForEach(session.entries) { entry in
                        ReplEntryView(entry: entry)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.entries.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var aiRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            TextField("Ask AI about $0…", text: $aiInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(askAI)
            if aiLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .overlay(alignment: .topLeading) {
            if let aiError {
                Text(aiError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 34)
                    .offset(y: -2)
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Text("›").foregroundStyle(.green).font(.system(size: 13, weight: .bold, design: .monospaced))
            TextField("JavaScript…", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(run)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private func run() {
        let code = input
        input = ""
        session.evaluate(code)
    }

    private func askAI() {
        let prompt = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !aiLoading else { return }
        aiLoading = true
        aiError = nil
        let preview = String(session.currentCapturePreview.prefix(4000))

        Task {
            do {
                let code = try await AIService.askInspectorJS(prompt: prompt, dataPreview: preview)
                aiInput = ""
                aiLoading = false
                session.evaluate(code, isAIGenerated: true)
            } catch {
                aiLoading = false
                aiError = error.localizedDescription
            }
        }
    }
}

private struct ReplEntryView: View {
    let entry: ReplEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.isAIGenerated ? "sparkles" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(entry.isAIGenerated ? Color.accentColor : .secondary)
                Text(entry.input)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }

            ForEach(entry.logs) { log in
                logView(log)
            }

            resultView
        }
    }

    @ViewBuilder
    private func logView(_ log: ReplLog) -> some View {
        if let value = log.value {
            ValueTree(root: value, rootLabel: log.level.rawValue)
        } else {
            Text(log.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color(for: log.level))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch entry.result {
        case .value(let text, let json):
            if let json {
                ValueTree(root: json, rootLabel: "←")
            } else {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        case .error(let message):
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .undefined:
            Text("undefined")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func color(for level: ReplLog.Level) -> Color {
        switch level {
        case .log, .info: return .primary
        case .warn: return .yellow
        case .error: return .red
        }
    }
}
