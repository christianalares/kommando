//
//  AIPromptOverlay.swift
//  Kommando
//
//  The ⌃↩ AI prompt. Generates a shell command and inserts it into the focused
//  terminal WITHOUT executing it — the user reviews and presses Enter.
//

import SwiftUI

struct AIPromptOverlay: View {
    let model: AppModel

    @State private var text = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)

                TextField("Describe a command…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(submit)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Generate", action: submit)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Inserts into the terminal without running it. Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: 540)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(radius: 24, y: 8)
        .onAppear { focused = true }
        .onExitCommand { model.aiPromptVisible = false }
    }

    private func submit() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isLoading else { return }
        guard let tab = model.activeTab,
              tab.tree.kind(of: tab.focusedLeafId) == .terminal else {
            errorMessage = "Focus a terminal pane first."
            return
        }

        let session = SessionRegistry.shared.terminalSession(for: tab.focusedLeafId)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let command = try await AIService.generateCommand(
                    prompt: prompt,
                    cwd: session.currentDirectory,
                    shell: shell
                )
                session.insertWithoutExecuting(command)
                isLoading = false
                model.aiPromptVisible = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
