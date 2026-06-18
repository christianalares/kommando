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
    /// Auto-derived title that tracks the focused pane's folder.
    var title: String
    /// User-supplied name; when set it overrides the auto-derived `title`.
    var customTitle: String?
    var tree: PaneNode
    var focusedLeafId: String
    /// When set (and present in the tree), this leaf is temporarily shown full-window,
    /// hiding the other panes. Transient — not persisted across launches.
    var zoomedLeafId: String?

    /// What the tab bar shows: the custom name if the user set one, else the auto title.
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        return title
    }

    init(kind: PaneKind = .terminal) {
        let leaf = PaneNode.newLeaf(kind)
        self.id = UUID().uuidString
        self.tree = leaf
        self.focusedLeafId = leaf.id
        self.title = kind == .repl ? "Inspector" : "Shell"
    }

    init(tree: PaneNode, focusedLeafId: String) {
        self.id = UUID().uuidString
        self.tree = tree
        self.focusedLeafId = focusedLeafId
        self.title = tree.firstLeafKind == .repl ? "Inspector" : "Shell"
    }

    init(restoring snapshot: TabSnapshot) {
        self.id = snapshot.id
        self.tree = snapshot.tree
        self.focusedLeafId = snapshot.tree.leafIds.contains(snapshot.focusedLeafId)
            ? snapshot.focusedLeafId
            : snapshot.tree.firstLeafId
        self.title = snapshot.title
        self.customTitle = snapshot.customTitle
    }
}

/// Something currently being dragged across the tab strip / pane area.
enum DragItem: Equatable {
    /// A whole tab, detached below the strip to be dropped into the pane area.
    case tab(id: String)
    /// A single pane (leaf), dragged to another pane or up to the strip.
    case pane(leafId: String)
}

@MainActor
@Observable
final class AppModel {
    var tabs: [Tab] = []
    var activeTabId: String = ""
    var aiPromptVisible = false

    // MARK: - Drag state (cross-view: tab→pane and pane→pane/tab)
    /// What is currently being dragged (a whole tab detached into the pane area, or a pane).
    var drag: DragItem?
    /// Cursor location in global coordinates during a drag.
    var dragLocation: CGPoint = .zero
    /// True when the cursor is over the tab strip (a pane dropped here pops out to a tab).
    var dragOverStrip = false
    /// The tab strip's global frame, used to detect drops onto the strip.
    var stripFrame: CGRect = .zero
    /// The resolved pane drop target (pane + edge) the content overlay highlights.
    var paneDropTarget: PaneDropTarget?

    /// The leaf id being dragged, if the current drag is a pane (used to exclude it as a
    /// drop target and to dim it while dragging).
    var draggedPaneLeafId: String? {
        if case .pane(let id) = drag { return id }
        return nil
    }

    func endDrag() {
        drag = nil
        dragOverStrip = false
        paneDropTarget = nil
    }

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
                TabSnapshot(id: $0.id, title: $0.title, customTitle: $0.customTitle, tree: $0.tree, focusedLeafId: $0.focusedLeafId)
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

    /// Sets a tab's custom name. An empty/whitespace name clears it, reverting to the
    /// auto-derived folder title.
    func renameTab(id: String, to newTitle: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        if tab.customTitle == nil {
            refreshTabTitle(tab)
        }
        bump()
    }

    /// Converts a whole tab into a pane of the target tab, inserting its pane tree against
    /// the dropped-on pane. The dragged tab's sessions are preserved (moved, not disposed).
    func convertTabToPane(draggedTabId: String, into targetTabId: String, target: PaneDropTarget) {
        guard draggedTabId != targetTabId,
              let draggedTab = tabs.first(where: { $0.id == draggedTabId }),
              let targetTab = tabs.first(where: { $0.id == targetTabId }),
              targetTab.tree.leafIds.contains(target.leafId) else {
            return
        }
        let subtree = draggedTab.tree
        // A tab has no slot to "swap" with, so a center drop falls back to a trailing split.
        targetTab.tree = targetTab.tree.inserting(subtree, nextTo: target.leafId, edge: target.edge ?? .trailing)
        targetTab.focusedLeafId = subtree.firstLeafId
        removeTabPreservingSessions(id: draggedTabId)
        activeTabId = targetTabId
        bump()
    }

    /// Moves a pane (leaf) next to another pane within the same tab. Sessions are preserved
    /// (the leaf id is just relocated in the tree). For two panes this reads as a swap.
    func movePane(leafId: String, to target: PaneDropTarget) {
        guard leafId != target.leafId,
              let tab = tabs.first(where: { $0.tree.leafIds.contains(leafId) }),
              tab.tree.leafIds.contains(target.leafId),
              let kind = tab.tree.kind(of: leafId) else {
            return
        }
        if let edge = target.edge {
            // Edge drop: relocate the pane into a new split beside the target.
            guard let pruned = tab.tree.removingLeaf(leafId) else { return }
            let subtree = PaneNode.leaf(id: leafId, kind: kind)
            tab.tree = pruned.inserting(subtree, nextTo: target.leafId, edge: edge)
        } else {
            // Center drop: swap the two panes' positions in place.
            guard let targetKind = tab.tree.kind(of: target.leafId) else { return }
            tab.tree = tab.tree.swappingLeaves(leafId, kind, target.leafId, targetKind)
        }
        tab.focusedLeafId = leafId
        bump()
    }

    /// Pops a pane out of its tab into a brand-new tab, preserving its session.
    func movePaneToNewTab(leafId: String) {
        guard let tab = tabs.first(where: { $0.tree.leafIds.contains(leafId) }),
              tab.tree.leafIds.count > 1,
              let kind = tab.tree.kind(of: leafId),
              let pruned = tab.tree.removingLeaf(leafId) else {
            return
        }
        tab.tree = pruned
        if tab.focusedLeafId == leafId {
            tab.focusedLeafId = pruned.firstLeafId
        }
        let newTab = Tab(tree: .leaf(id: leafId, kind: kind), focusedLeafId: leafId)
        tabs.append(newTab)
        activeTabId = newTab.id
        bump()
    }

    /// Removes a tab from the strip WITHOUT disposing its sessions (they live on elsewhere,
    /// e.g. after being merged into another tab as panes).
    private func removeTabPreservingSessions(id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if activeTabId == id, !tabs.isEmpty {
            activeTabId = tabs[max(0, idx - 1)].id
        }
    }

    /// Reorders a tab to a new index. `toIndex` is interpreted in the array *after* the
    /// tab has been removed (i.e. the insertion slot among the remaining tabs).
    func moveTab(id: String, toIndex: Int) {
        guard let fromIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let moved = tabs.remove(at: fromIndex)
        let insertAt = max(0, min(toIndex, tabs.count))
        guard insertAt != fromIndex else {
            tabs.insert(moved, at: fromIndex)
            return
        }
        tabs.insert(moved, at: insertAt)
        bump()
    }

    // MARK: - Splits

    /// Toggles full-window zoom for the focused pane of the active tab. Pressing once
    /// maximizes it; pressing again restores the previous split layout.
    func toggleZoomFocused() {
        guard let tab = activeTab else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
            if tab.zoomedLeafId == tab.focusedLeafId {
                tab.zoomedLeafId = nil
            } else if tab.tree.leafIds.contains(tab.focusedLeafId) {
                tab.zoomedLeafId = tab.focusedLeafId
            }
        }
        bump()
    }

    func splitActive(axis: SplitAxis, kind: PaneKind = .terminal) {
        guard let tab = activeTab else { return }
        _ = splitLeaf(tab.focusedLeafId, axis: axis, kind: kind)
    }

    /// Splits a specific pane (in whatever tab owns it), focuses the new pane, and returns its
    /// leaf id. Used by both the UI (via `splitActive`) and the MCP server, which may target a
    /// pane in a non-active tab.
    @discardableResult
    func splitLeaf(_ leafId: String, axis: SplitAxis, kind: PaneKind = .terminal) -> String? {
        guard let tab = tabs.first(where: { $0.tree.leafIds.contains(leafId) }) else { return nil }
        // Splitting while zoomed would hide the new pane; restore the layout first.
        tab.zoomedLeafId = nil
        let inheritedDirectory: String? = {
            guard kind == .terminal, tab.tree.kind(of: leafId) == .terminal else { return nil }
            return SessionRegistry.shared.existingTerminalSession(for: leafId)?.resolvedDirectory
        }()
        let newLeafId = UUID().uuidString
        tab.tree = tab.tree.splittingLeaf(leafId, axis: axis, newKind: kind, newLeafId: newLeafId)
        tab.focusedLeafId = newLeafId
        if kind == .terminal, let inheritedDirectory {
            SessionRegistry.shared.terminalSession(for: newLeafId).startDirectory = inheritedDirectory
        }
        bump()
        return newLeafId
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
                tabTitle: tab.displayTitle,
                cwd: session?.resolvedDirectory,
                shell: shell,
                output: session?.snapshotOutput(maxLines: 80) ?? ""
            )
        }
        return TabContext(tabTitle: tab.displayTitle, cwd: nil, shell: shell, output: "")
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
