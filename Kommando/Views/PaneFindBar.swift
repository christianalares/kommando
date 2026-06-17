//
//  PaneFindBar.swift
//  Kommando
//
//  A ⌘F find bar that floats at the top-right of a terminal pane. Drives SwiftTerm's
//  built-in search (which selects/highlights and scrolls to the current match).
//

import SwiftUI
import SwiftTerm

struct PaneFindBar: View {
    @Bindable var session: TerminalSession

    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Find", text: $session.findTerm)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .focused($fieldFocused)
                .onSubmit { findNext() }
                .onExitCommand { close() }
                .onChange(of: session.findTerm) { _, term in
                    performIncrementalSearch(term)
                }

            iconButton("chevron.up", help: "Previous (⇧⌘G)") { findPrevious() }
            iconButton("chevron.down", help: "Next (⌘G)") { findNext() }
            iconButton("xmark", help: "Close (Esc)") { close() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .onAppear {
            fieldFocused = true
            performIncrementalSearch(session.findTerm)
        }
        .onChange(of: session.findFocusToken) { _, _ in
            fieldFocused = true
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func performIncrementalSearch(_ term: String) {
        session.findNext()
    }

    private func findNext() {
        session.findNext()
    }

    private func findPrevious() {
        session.findPrevious()
    }

    private func close() {
        session.clearFind()
        session.findVisible = false
        // Return focus to the terminal so typing continues normally.
        if let window = session.terminalView.window {
            window.makeFirstResponder(session.terminalView)
        }
    }
}
