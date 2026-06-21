//
//  TerminalControl.swift
//  Kommando
//
//  The bridge between the MCP control socket and the app's live terminal state. Every
//  operation resolves a session id (a pane's leaf id) to the window/tab that owns it,
//  so an external AI tool can list, read, and drive any pane — not just the focused one.
//

import AppKit
import Darwin
import SwiftTerm

/// A serializable description of one terminal/REPL pane, surfaced to MCP clients so the
/// model can pick which session to operate on from context (cwd, title, busy state).
struct MCPSessionInfo: Encodable {
    let id: String
    let kind: String
    let title: String
    let cwd: String?
    let busy: Bool
    let space: String
    let tab: String
    let window: Int
    /// True for the focused pane of its window's active tab (the default target).
    let focused: Bool
}

enum TerminalControlError: Error, CustomStringConvertible {
    case noWindow
    case sessionNotFound
    case notATerminal
    case badInput(String)

    var description: String {
        switch self {
        case .noWindow: return "No Kommando window is open."
        case .sessionNotFound: return "No terminal session matches that id."
        case .notATerminal: return "That session is an inspector pane, not a terminal."
        case .badInput(let why): return why
        }
    }
}

@MainActor
enum TerminalControl {
    // MARK: - Listing

    static func listSessions() -> [MCPSessionInfo] {
        var result: [MCPSessionInfo] = []
        let current = AppModelRegistry.shared.current()
        for (windowIndex, pair) in AppModelRegistry.shared.all.enumerated() {
            let model = pair.model
            for space in model.spaces {
                let isActiveSpace = space.id == model.activeSpaceId
                for tab in space.tabs {
                    for leafId in tab.tree.leafIds {
                        let kind = tab.tree.kind(of: leafId)
                        let isFocusedPane = isActiveSpace
                            && tab.id == space.activeTabId
                            && tab.focusedLeafId == leafId
                            && model === current
                        if kind == .repl {
                            result.append(MCPSessionInfo(
                                id: leafId,
                                kind: "inspector",
                                title: "Inspector",
                                cwd: nil,
                                busy: false,
                                space: space.name,
                                tab: tab.displayTitle,
                                window: windowIndex + 1,
                                focused: isFocusedPane
                            ))
                        } else {
                            let session = SessionRegistry.shared.existingTerminalSession(for: leafId)
                            result.append(MCPSessionInfo(
                                id: leafId,
                                kind: "terminal",
                                title: session?.title ?? "Shell",
                                cwd: session?.resolvedDirectory,
                                busy: session.map { isBusy($0) } ?? false,
                                space: space.name,
                                tab: tab.displayTitle,
                                window: windowIndex + 1,
                                focused: isFocusedPane
                            ))
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: - Read / write / control

    static func read(id: String?, lines: Int) throws -> String {
        let (_, _, session) = try resolveTerminal(id)
        session.startIfNeeded()
        let output = session.snapshotOutput(maxLines: max(1, lines))
        return output.isEmpty ? "(the terminal is currently empty)" : output
    }

    @discardableResult
    static func write(id: String?, text: String, execute: Bool) throws -> String {
        let (_, _, session) = try resolveTerminal(id)
        session.startIfNeeded()
        if execute {
            session.executeCommand(text)
        } else {
            session.insertWithoutExecuting(text)
        }
        return session.id
    }

    @discardableResult
    static func sendControl(id: String?, letter: String) throws -> String {
        guard let bytes = controlBytes(for: letter) else {
            throw TerminalControlError.badInput("Unsupported control character: \(letter)")
        }
        let (_, _, session) = try resolveTerminal(id)
        session.startIfNeeded()
        session.terminalView.send(txt: String(decoding: bytes, as: UTF8.self))
        return session.id
    }

    // MARK: - Session management

    @discardableResult
    static func createTerminal(inspector: Bool) throws -> String {
        guard let model = AppModelRegistry.shared.current() else {
            throw TerminalControlError.noWindow
        }
        model.newTab(kind: inspector ? .repl : .terminal)
        guard let leafId = model.activeTab?.tree.firstLeafId else {
            throw TerminalControlError.noWindow
        }
        if !inspector {
            SessionRegistry.shared.terminalSession(for: leafId).startIfNeeded()
        }
        return leafId
    }

    /// Splits a pane and returns the new pane's session id. A nil id splits the focused pane of
    /// the current window. `direction` is "vertical" (stacked, top/bottom) or "horizontal"
    /// (side by side, left/right); "up"/"down"/"left"/"right" are accepted as aliases.
    @discardableResult
    static func split(id: String?, direction: String, inspector: Bool) throws -> String {
        let axis: SplitAxis
        switch direction.lowercased() {
        case "horizontal", "h", "right", "left":
            axis = .horizontal
        case "vertical", "v", "down", "up", "":
            axis = .vertical
        default:
            throw TerminalControlError.badInput("direction must be 'horizontal' or 'vertical' (got '\(direction)')")
        }

        let model: AppModel
        let leafId: String
        if let id, !id.isEmpty {
            guard let (m, s, t) = owner(of: id) else { throw TerminalControlError.sessionNotFound }
            model = m
            leafId = id
            // Make the owning space + tab active so the new split is visible.
            model.selectSpace(id: s.id)
            model.selectTab(id: t.id)
        } else {
            guard let m = AppModelRegistry.shared.current(), let t = m.activeTab else {
                throw TerminalControlError.noWindow
            }
            model = m
            leafId = t.focusedLeafId
        }

        guard let newLeafId = model.splitLeaf(leafId, axis: axis, kind: inspector ? .repl : .terminal) else {
            throw TerminalControlError.sessionNotFound
        }
        if !inspector {
            SessionRegistry.shared.terminalSession(for: newLeafId).startIfNeeded()
        }
        return newLeafId
    }

    @discardableResult
    static func focus(id: String) throws -> String {
        guard let (model, space, tab) = owner(of: id) else {
            throw TerminalControlError.sessionNotFound
        }
        model.selectSpace(id: space.id)
        model.selectTab(id: tab.id)
        model.focusLeaf(id)
        AppModelRegistry.shared.setCurrent(model)
        if let window = AppModelRegistry.shared.window(for: model) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return id
    }

    @discardableResult
    static func close(id: String) throws -> String {
        guard let (model, _, _) = owner(of: id) else {
            throw TerminalControlError.sessionNotFound
        }
        model.closeLeaf(id)
        return id
    }

    // MARK: - Resolution

    /// Finds the model + space + tab that contain a leaf id (across all spaces, not just the
    /// active one).
    private static func owner(of leafId: String) -> (AppModel, Space, Tab)? {
        for pair in AppModelRegistry.shared.all {
            for space in pair.model.spaces {
                if let tab = space.tabs.first(where: { $0.tree.leafIds.contains(leafId) }) {
                    return (pair.model, space, tab)
                }
            }
        }
        return nil
    }

    /// Resolves a target terminal session. A nil id targets the focused pane of the
    /// current window (matching how iterm-mcp targets the active session).
    private static func resolveTerminal(_ id: String?) throws -> (AppModel, Tab, TerminalSession) {
        let model: AppModel
        let tab: Tab
        let leafId: String

        if let id, !id.isEmpty {
            guard let (m, _, t) = owner(of: id) else { throw TerminalControlError.sessionNotFound }
            model = m
            tab = t
            leafId = id
        } else {
            guard let m = AppModelRegistry.shared.current(), let t = m.activeTab else {
                throw TerminalControlError.noWindow
            }
            model = m
            tab = t
            leafId = t.focusedLeafId
        }

        guard tab.tree.kind(of: leafId) == .terminal else {
            throw TerminalControlError.notATerminal
        }
        return (model, tab, SessionRegistry.shared.terminalSession(for: leafId))
    }

    // MARK: - Helpers

    /// A terminal is "busy" when its shell has at least one child process (a command is
    /// running in the foreground). More reliable than CPU heuristics since we own the PTY.
    private static func isBusy(_ session: TerminalSession) -> Bool {
        guard let pid = session.terminalView.process?.shellPid, pid > 0 else { return false }
        return hasChildProcesses(pid)
    }

    private static func hasChildProcesses(_ pid: pid_t) -> Bool {
        let capacity = 256
        var pids = [pid_t](repeating: 0, count: capacity)
        // PROC_PPID_ONLY (6): list pids whose parent process id is `pid`.
        let byteCount = proc_listpids(6, UInt32(pid), &pids, Int32(MemoryLayout<pid_t>.size * capacity))
        guard byteCount > 0 else { return false }
        let count = Int(byteCount) / MemoryLayout<pid_t>.size
        return pids.prefix(count).contains { $0 != 0 }
    }

    /// Maps a letter (e.g. "C") or symbol (e.g. "]") to its control byte (Ctrl-C = 0x03).
    private static func controlBytes(for letter: String) -> [UInt8]? {
        guard let scalar = letter.uppercased().unicodeScalars.first else { return nil }
        let v = scalar.value
        // @ A–Z [ \ ] ^ _  map to 0x00–0x1F.
        if v >= 64 && v <= 95 {
            return [UInt8(v - 64)]
        }
        return nil
    }
}
