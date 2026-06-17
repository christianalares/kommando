//
//  SessionRegistry.swift
//  Kommando
//
//  Caches live sessions by leaf id so the underlying PTY/JS context survives SwiftUI
//  re-renders and tab switches. Sessions are created lazily and disposed when a pane
//  is closed.
//

import Foundation

@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()

    private var terminals: [String: TerminalSession] = [:]
    private var repls: [String: ReplSession] = [:]

    func terminalSession(for id: String) -> TerminalSession {
        if let existing = terminals[id] {
            return existing
        }
        let session = TerminalSession(id: id)
        terminals[id] = session
        return session
    }

    /// Returns an already-created terminal session without creating one.
    func existingTerminalSession(for id: String) -> TerminalSession? {
        terminals[id]
    }

    func replSession(for id: String) -> ReplSession {
        if let existing = repls[id] {
            return existing
        }
        let session = ReplSession(id: id)
        repls[id] = session
        return session
    }

    func dispose(_ id: String) {
        terminals[id]?.terminate()
        terminals[id] = nil
        repls[id] = nil
    }

    func applyThemeToAll() {
        for session in terminals.values {
            session.applyTheme()
        }
    }
}
