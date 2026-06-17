//
//  AppModel.swift
//  Kommando
//
//  Top-level observable state: the open tabs and the active selection. Owns all the
//  mutating operations driven by the tab bar and keyboard shortcuts.
//

import SwiftUI
import AppKit

@MainActor
@Observable
final class Tab: Identifiable {
    let id: String
    var title: String
    var tree: PaneNode
    var focusedLeafId: String

    init(kind: PaneKind = .terminal) {
        let leaf = PaneNode.newLeaf(kind)
        self.id = UUID().uuidString
        self.tree = leaf
        self.focusedLeafId = leaf.id
        self.title = kind == .repl ? "Inspector" : "Shell"
    }

    init(restoring snapshot: TabSnapshot) {
        self.id = snapshot.id
        self.tree = snapshot.tree
        self.focusedLeafId = snapshot.tree.leafIds.contains(snapshot.focusedLeafId)
            ? snapshot.focusedLeafId
            : snapshot.tree.firstLeafId
        self.title = snapshot.title
    }
}

@MainActor
@Observable
final class AppModel {
    var tabs: [Tab] = []
    var activeTabId: String = ""
    var aiPromptVisible = false

    /// Bumped on any structural change worth persisting (tabs/panes/fractions/focus/title).
    private(set) var revision = 0

    /// Only the first window to appear after launch restores the saved session; later
    /// windows (⌘N) start fresh.
    private static var didRestoreInitialWindow = false

    /// The AI sidebar's conversations + state for this window.
    let chat = AIChatStore()

    init() {
        // Tabs are created in `bootstrap()` (called when the window appears) so a restored
        // session can populate them before any pane mounts and spawns a shell.
        chat.contextProvider = { [weak self] in self?.aiCurrentContext() }
        chat.toolExecutor = { [weak self] name, input in
            await self?.aiToolExecute(name, input: input) ?? "Assistant unavailable."
        }
    }

    private func bump() {
        revision += 1
    }

    // MARK: - Session restore

    /// Populates this window: restores the saved session into the first window after launch,
    /// otherwise opens a single fresh tab.
    func bootstrap() {
        guard tabs.isEmpty else { return }
        if !AppModel.didRestoreInitialWindow {
            AppModel.didRestoreInitialWindow = true
            if let json = SessionPersistence.load(), restore(fromJSON: json) {
                return
            }
        }
        newTab()
    }

    /// A JSON snapshot of the current layout (tabs, panes, focus, terminal directories).
    func snapshotJSON() -> String {
        var directories: [String: String] = [:]
        for tab in tabs {
            for leafId in tab.tree.leafIds where tab.tree.kind(of: leafId) == .terminal {
                if let dir = SessionRegistry.shared.existingTerminalSession(for: leafId)?.resolvedDirectory {
                    directories[leafId] = dir
                }
            }
        }
        let snapshot = SessionSnapshot(
            tabs: tabs.map {
                TabSnapshot(id: $0.id, title: $0.title, tree: $0.tree, focusedLeafId: $0.focusedLeafId)
            },
            activeTabId: activeTabId,
            directories: directories
        )
        guard let data = try? JSONEncoder().encode(snapshot),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    @discardableResult
    private func restore(fromJSON json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              !snapshot.tabs.isEmpty else {
            return false
        }
        // Seed each terminal's start directory before its pane mounts so the shell reopens
        // in the right place.
        for (leafId, dir) in snapshot.directories {
            SessionRegistry.shared.terminalSession(for: leafId).startDirectory = dir
        }
        tabs = snapshot.tabs.map { Tab(restoring: $0) }
        activeTabId = tabs.contains(where: { $0.id == snapshot.activeTabId })
            ? snapshot.activeTabId
            : (tabs.first?.id ?? "")
        return true
    }

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabId }
    }

    // MARK: - Tabs

    func newTab(kind: PaneKind = .terminal) {
        let inheritedDirectory = kind == .terminal ? currentTerminalDirectory() : nil
        let tab = Tab(kind: kind)
        if kind == .terminal, let inheritedDirectory {
            SessionRegistry.shared.terminalSession(for: tab.tree.firstLeafId).startDirectory = inheritedDirectory
        }
        tabs.append(tab)
        activeTabId = tab.id
        bump()
    }

    func selectTab(id: String) {
        activeTabId = id
        bump()
    }

    func selectTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabId = tabs[index].id
        bump()
    }

    func cycleTab(_ delta: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == activeTabId }), !tabs.isEmpty else { return }
        let count = tabs.count
        let next = ((current + delta) % count + count) % count
        activeTabId = tabs[next].id
        bump()
    }

    // MARK: - Splits

    func splitActive(axis: SplitAxis, kind: PaneKind = .terminal) {
        guard let tab = activeTab else { return }
        let inheritedDirectory = kind == .terminal ? currentTerminalDirectory() : nil
        let newLeafId = UUID().uuidString
        tab.tree = tab.tree.splittingLeaf(tab.focusedLeafId, axis: axis, newKind: kind, newLeafId: newLeafId)
        tab.focusedLeafId = newLeafId
        if kind == .terminal, let inheritedDirectory {
            SessionRegistry.shared.terminalSession(for: newLeafId).startDirectory = inheritedDirectory
        }
        bump()
    }

    /// The working directory of the focused terminal pane (used so new tabs/panes open
    /// in the same place the user was).
    private func currentTerminalDirectory() -> String? {
        guard let tab = activeTab else { return nil }
        let leafId = tab.focusedLeafId
        guard tab.tree.kind(of: leafId) == .terminal else { return nil }
        return SessionRegistry.shared.existingTerminalSession(for: leafId)?.resolvedDirectory
    }

    func setFractions(tabId: String, splitId: String, fractions: [Double]) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.tree = tab.tree.settingFractions(splitId: splitId, fractions: fractions)
        bump()
    }

    func focusLeaf(_ id: String) {
        activeTab?.focusedLeafId = id
        if let tab = activeTab {
            refreshTabTitle(tab)
        }
        bump()
    }

    enum PaneDirection {
        case left, right, up, down
    }

    /// Moves focus to the nearest pane in the given direction within the active tab.
    func focusPane(_ direction: PaneDirection) {
        guard let tab = activeTab else { return }
        let leaves = PaneLayoutEngine.layout(
            tab.tree,
            in: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            dividerThickness: 6
        ).leaves
        guard leaves.count > 1, let current = leaves.first(where: { $0.id == tab.focusedLeafId }) else { return }

        let source = current.rect
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        var best: (id: String, score: CGFloat)?

        for leaf in leaves where leaf.id != current.id {
            let rect = leaf.rect
            let inDirection: Bool
            switch direction {
            case .right: inDirection = rect.minX >= source.maxX - 1
            case .left: inDirection = rect.maxX <= source.minX + 1
            case .down: inDirection = rect.minY >= source.maxY - 1
            case .up: inDirection = rect.maxY <= source.minY + 1
            }
            guard inDirection else { continue }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let primary: CGFloat
            let perpendicular: CGFloat
            switch direction {
            case .left, .right:
                primary = abs(center.x - sourceCenter.x)
                perpendicular = abs(center.y - sourceCenter.y)
            case .up, .down:
                primary = abs(center.y - sourceCenter.y)
                perpendicular = abs(center.x - sourceCenter.x)
            }
            // Prefer panes aligned along the travel axis, then the closest one.
            let score = primary + perpendicular * 2
            if best == nil || score < best!.score {
                best = (leaf.id, score)
            }
        }

        if let best {
            focusLeaf(best.id)
        }
    }

    /// Updates a tab's title to the folder name of its focused terminal pane.
    func refreshTabTitle(_ tab: Tab) {
        let leafId = tab.focusedLeafId
        let newTitle: String
        if tab.tree.kind(of: leafId) == .repl {
            newTitle = "Inspector"
        } else {
            let directory = SessionRegistry.shared.existingTerminalSession(for: leafId)?.resolvedDirectory
            newTitle = Self.folderName(for: directory)
        }
        guard tab.title != newTitle else { return }
        tab.title = newTitle
        bump()
    }

    private static func folderName(for path: String?) -> String {
        guard let path, !path.isEmpty else { return "Shell" }
        if path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "~"
        }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    // MARK: - Find

    func showFindInFocusedPane() {
        guard let tab = activeTab else { return }
        let leafId = tab.focusedLeafId
        guard tab.tree.kind(of: leafId) == .terminal else { return }
        let session = SessionRegistry.shared.terminalSession(for: leafId)
        session.findVisible = true
        session.findFocusToken += 1
    }

    func findNextInFocusedPane() {
        focusedTerminalSession()?.findNext()
    }

    func findPreviousInFocusedPane() {
        focusedTerminalSession()?.findPrevious()
    }

    private func focusedTerminalSession() -> TerminalSession? {
        guard let tab = activeTab else { return nil }
        let leafId = tab.focusedLeafId
        guard tab.tree.kind(of: leafId) == .terminal else { return nil }
        return SessionRegistry.shared.existingTerminalSession(for: leafId)
    }

    // MARK: - AI sidebar context + tools

    /// Live context (cwd + visible output) of the focused pane, fed to the assistant.
    func aiCurrentContext() -> TabContext? {
        guard let tab = activeTab else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let leafId = tab.focusedLeafId
        if tab.tree.kind(of: leafId) == .terminal {
            let session = SessionRegistry.shared.existingTerminalSession(for: leafId)
            return TabContext(
                tabTitle: tab.title,
                cwd: session?.resolvedDirectory,
                shell: shell,
                output: session?.snapshotOutput(maxLines: 80) ?? ""
            )
        }
        return TabContext(tabTitle: tab.title, cwd: nil, shell: shell, output: "")
    }

    /// Executes a tool requested by the assistant against the focused terminal pane.
    func aiToolExecute(_ name: String, input: [String: Any]) async -> String {
        switch AIToolKind(rawValue: name) {
        case .readTerminalOutput:
            guard let tab = activeTab, tab.tree.kind(of: tab.focusedLeafId) == .terminal,
                  let session = SessionRegistry.shared.existingTerminalSession(for: tab.focusedLeafId) else {
                return "No focused terminal pane to read."
            }
            let output = session.snapshotOutput(maxLines: 200)
            return output.isEmpty ? "(the terminal is currently empty)" : output
        case .insertCommand:
            guard let command = (input["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                return "No command provided."
            }
            guard let tab = activeTab, tab.tree.kind(of: tab.focusedLeafId) == .terminal else {
                return "No focused terminal pane to insert into."
            }
            let session = SessionRegistry.shared.terminalSession(for: tab.focusedLeafId)
            if chat.autoExecute {
                session.executeCommand(command)
                return "Executed in the terminal: \(command)"
            }
            session.insertWithoutExecuting(command)
            return "Inserted into the terminal (not executed): \(command)"
        case .none:
            return "Unknown tool: \(name)"
        }
    }

    /// Inserts a command into the focused terminal (used by sidebar code-block actions).
    func insertCommandIntoFocusedTerminal(_ command: String) {
        guard let tab = activeTab, tab.tree.kind(of: tab.focusedLeafId) == .terminal else { return }
        SessionRegistry.shared.terminalSession(for: tab.focusedLeafId).insertWithoutExecuting(command)
    }

    /// Runs a user-defined command in the focused terminal (from the Commands menu/hotkey).
    func runUserCommand(_ command: UserCommand) {
        let trimmed = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let tab = activeTab, tab.tree.kind(of: tab.focusedLeafId) == .terminal else { return }
        let session = SessionRegistry.shared.terminalSession(for: tab.focusedLeafId)
        if command.execute {
            session.executeCommand(trimmed)
        } else {
            session.insertWithoutExecuting(trimmed)
        }
    }

    // MARK: - Closing (⌘W cascade: pane → tab → window)

    func closeFocused() {
        guard let tab = activeTab else { return }
        let leafId = tab.focusedLeafId
        if let newTree = tab.tree.removingLeaf(leafId) {
            SessionRegistry.shared.dispose(leafId)
            tab.tree = newTree
            tab.focusedLeafId = newTree.firstLeafId
            bump()
        } else {
            closeTab(id: tab.id)
        }
    }

    func closeTab(id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        for leafId in tabs[idx].tree.leafIds {
            SessionRegistry.shared.dispose(leafId)
        }
        tabs.remove(at: idx)

        if tabs.isEmpty {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        if activeTabId == id {
            activeTabId = tabs[max(0, idx - 1)].id
        }
        bump()
    }

    /// Closes a specific pane (by leaf id), cascading to tab/window close if it was the
    /// last one. Used when a pane's shell exits on its own. No-op if the leaf is gone.
    func closeLeaf(_ leafId: String) {
        guard let tab = tabs.first(where: { $0.tree.leafIds.contains(leafId) }) else { return }
        if let newTree = tab.tree.removingLeaf(leafId) {
            SessionRegistry.shared.dispose(leafId)
            tab.tree = newTree
            if tab.focusedLeafId == leafId {
                tab.focusedLeafId = newTree.firstLeafId
            }
            bump()
        } else {
            closeTab(id: tab.id)
        }
    }

    /// Tears down every session in this window's tabs. Called when the window closes so
    /// shell processes/PTYs don't linger after a window is dismissed.
    func disposeAllSessions() {
        for tab in tabs {
            for leafId in tab.tree.leafIds {
                SessionRegistry.shared.dispose(leafId)
            }
        }
        tabs.removeAll()
    }
}
