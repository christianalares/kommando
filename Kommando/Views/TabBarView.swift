//
//  TabBarView.swift
//  Kommando
//
//  Custom in-window tab strip. Each tab owns a pane tree; the active tab is highlighted.
//

import SwiftUI

struct TabBarView: View {
    let model: AppModel

    /// The tab currently being dragged for reordering, if any.
    @State private var draggingTabId: String?
    /// Horizontal translation of the dragged chip (follows the cursor; not animated).
    @State private var dragOffset: CGFloat = 0
    /// Vertical translation of the dragged chip while detaching into the pane area.
    @State private var dragOffsetY: CGFloat = 0
    /// The dragged tab's original index when the drag began.
    @State private var dragStartIndex: Int = 0
    /// The index the dragged tab would land at if dropped now (drives the gap shift).
    @State private var dragTargetIndex: Int = 0
    /// Width (incl. spacing) of the dragged tab, used to size the gap and shifts.
    @State private var draggedSlotWidth: CGFloat = 0
    /// Each tab's frame in the tab-strip space (stable during a drag — the model isn't
    /// reordered until drop — so reads don't feed back into the gesture).
    @State private var tabFrames: [String: CGRect] = [:]
    /// The tab whose name is being edited inline, if any.
    @State private var editingTabId: String?
    @State private var editingText = ""

    private let stripSpace = "tabstrip"
    private let tabSpacing: CGFloat = 4
    /// Downward drag past this distance detaches the tab toward the pane area.
    private let detachThreshold: CGFloat = 26

    var body: some View {
        // Tabs scroll horizontally; the new-tab button stays pinned to the right so it's
        // always reachable. A flexible window-drag filler fills any empty strip space so
        // that area still moves the window (the window is otherwise non-movable).
        HStack(spacing: 6) {
            SpaceChip(model: model)

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: tabSpacing) {
                            ForEach(model.tabs) { tab in
                                chip(for: tab)
                            }

                            WindowDragArea()
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        // Force the content at least as wide as the viewport so the filler
                        // expands into the empty space; it collapses to 0 when tabs overflow.
                        .frame(minWidth: geo.size.width, alignment: .leading)
                        .padding(.vertical, 2)
                        .coordinateSpace(.named(stripSpace))
                        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
                    }
                    .frame(height: 34)
                    .onChange(of: model.activeTabId) {
                        scrollToActive(proxy)
                    }
                    .onChange(of: model.tabs.count) {
                        scrollToActive(proxy)
                    }
                    .onAppear {
                        scrollToActive(proxy, animated: false)
                    }
                }
                .background(
                    Color.clear.preference(key: StripFrameKey.self, value: geo.frame(in: .global))
                )
                // Highlight the strip when a pane is dragged here (drop = pop out to a tab).
                .overlay {
                    if model.dragOverStrip, case .pane = model.drag {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                            )
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 34)

            CircularIconButton(
                systemName: "plus",
                diameter: 26,
                iconSize: 12,
                help: "New Tab (⌘T)",
                action: { model.newTab() }
            )

            CircularIconButton(
                systemName: "sparkles",
                diameter: 26,
                iconSize: 12,
                help: "Toggle Assistant (⌘I)",
                isActive: model.chat.sidebarVisible,
                action: { withAnimation(.easeOut(duration: 0.2)) { model.chat.toggleSidebar() } }
            )
        }
        .onPreferenceChange(StripFrameKey.self) { model.stripFrame = $0 }
    }

    @ViewBuilder
    private func chip(for tab: Tab) -> some View {
        let isDragging = draggingTabId == tab.id
        let isDetached = model.drag == .tab(id: tab.id)
        TabChip(
            title: tab.displayTitle,
            kind: tab.tree.firstLeafKind,
            isActive: tab.id == model.activeTabId,
            hasCustomName: tab.customTitle != nil,
            isEditing: editingTabId == tab.id,
            editingText: $editingText,
            onSelect: { model.selectTab(id: tab.id) },
            onClose: { model.closeTab(id: tab.id) },
            onBeginRename: { beginRename(tab) },
            onCommitRename: { commitRename(tab) },
            onCancelRename: { editingTabId = nil },
            onResetName: { model.renameTab(id: tab.id, to: "") }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabFrameKey.self,
                    value: [tab.id: geo.frame(in: .named(stripSpace))]
                )
            }
        )
        // Hide the in-strip chip once it has detached into the pane area (a floating
        // preview follows the cursor there instead); otherwise dim it slightly while dragging.
        .opacity(isDragging ? (isDetached ? 0 : 0.75) : 1)
        // Dragged chip: float with the cursor. Others: slide to open a reorder gap.
        .offset(
            x: isDragging ? dragOffset : gapShift(for: tab),
            y: isDragging ? dragOffsetY : 0
        )
        .zIndex(isDragging ? 1 : 0)
        // Only the gap shifts animate; the dragged chip tracks the cursor instantly.
        .animation(.easeInOut(duration: 0.18), value: dragTargetIndex)
        .animation(.easeInOut(duration: 0.18), value: draggingTabId)
        .id(tab.id)
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                    if draggingTabId != tab.id {
                        beginDrag(tab)
                    }
                    let canDetach = tab.id != model.activeTabId
                    if canDetach && value.translation.height > detachThreshold {
                        // Detached: follow the cursor into the pane area; close reorder gaps.
                        model.drag = .tab(id: tab.id)
                        model.dragLocation = value.location
                        model.dragOverStrip = false
                        dragOffset = value.translation.width
                        dragOffsetY = value.translation.height
                        dragTargetIndex = dragStartIndex
                    } else {
                        // Reordering within the strip.
                        clearContentDrag()
                        dragOffset = value.translation.width
                        dragOffsetY = 0
                        dragTargetIndex = targetIndex(draggedId: tab.id, translationX: value.translation.width)
                    }
                }
                .onEnded { _ in
                    if model.drag != nil, let target = model.paneDropTarget {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.convertTabToPane(
                                draggedTabId: tab.id,
                                into: model.activeTabId,
                                target: target
                            )
                        }
                        resetDrag()
                    } else {
                        endDrag(tab)
                    }
                }
        )
    }

    private func clearContentDrag() {
        if case .tab = model.drag {
            model.endDrag()
        }
    }

    private func resetDrag() {
        draggingTabId = nil
        dragOffset = 0
        dragOffsetY = 0
        model.endDrag()
    }

    /// Horizontal shift applied to a non-dragged tab to open the gap for the drop slot.
    private func gapShift(for tab: Tab) -> CGFloat {
        guard draggingTabId != nil,
              let index = model.tabs.firstIndex(where: { $0.id == tab.id }),
              index != dragStartIndex else {
            return 0
        }
        // Rank ignoring the dragged tab (it's removed before re-insertion).
        let rank = index > dragStartIndex ? index - 1 : index
        var shift: CGFloat = 0
        if index > dragStartIndex {
            shift -= draggedSlotWidth
        }
        if rank >= dragTargetIndex {
            shift += draggedSlotWidth
        }
        return shift
    }

    private func beginDrag(_ tab: Tab) {
        let index = model.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        dragStartIndex = index
        dragTargetIndex = index
        draggedSlotWidth = (tabFrames[tab.id]?.width ?? 100) + tabSpacing
        draggingTabId = tab.id
    }

    /// Where the dragged tab would land: the count of other tabs whose center it has
    /// passed. Uses the *stable* captured frames (the model isn't reordered mid-drag).
    private func targetIndex(draggedId: String, translationX: CGFloat) -> Int {
        let draggedCenter = (tabFrames[draggedId]?.midX ?? 0) + translationX
        var index = 0
        for tab in model.tabs where tab.id != draggedId {
            if let frame = tabFrames[tab.id], frame.midX < draggedCenter {
                index += 1
            }
        }
        return index
    }

    private func endDrag(_ tab: Tab) {
        let target = dragTargetIndex
        withAnimation(.easeInOut(duration: 0.18)) {
            model.moveTab(id: tab.id, toIndex: target)
            draggingTabId = nil
            dragOffset = 0
            dragOffsetY = 0
        }
        clearContentDrag()
    }

    private func beginRename(_ tab: Tab) {
        model.selectTab(id: tab.id)
        editingText = tab.displayTitle
        editingTabId = tab.id
    }

    private func commitRename(_ tab: Tab) {
        model.renameTab(id: tab.id, to: editingText)
        editingTabId = nil
    }

    private func scrollToActive(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let id = model.activeTabId
        guard !id.isEmpty else { return }
        // anchor: nil scrolls the minimum amount to reveal the tab, and does nothing if
        // it's already fully visible — so we only scroll when necessary.
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: nil)
            }
        } else {
            proxy.scrollTo(id, anchor: nil)
        }
    }
}

/// Collects each tab's frame (in the tab-strip coordinate space) so the reorder drag can
/// find which tab sits under the cursor.
private struct TabFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct StripFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct TabChip: View {
    let title: String
    let kind: PaneKind
    let isActive: Bool
    let hasCustomName: Bool
    let isEditing: Bool
    @Binding var editingText: String
    let onSelect: () -> Void
    let onClose: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onResetName: () -> Void

    @State private var isHovering = false
    @FocusState private var isFieldFocused: Bool

    private var iconName: String {
        kind == .repl ? "chevron.left.forwardslash.chevron.right" : "apple.terminal"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.green : Color.secondary)

            if isEditing {
                TextField("Tab name", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($isFieldFocused)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
                    .onChange(of: isFieldFocused) { _, focused in
                        // Commit when focus leaves the field (e.g. clicking elsewhere).
                        if !focused, isEditing {
                            onCommitRename()
                        }
                    }
                    .onAppear { isFieldFocused = true }
            } else {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }

            // Always present (stable width); just toggle visibility to avoid layout shift.
            CircularIconButton(
                systemName: "xmark",
                diameter: 18,
                iconSize: 9,
                help: "Close Tab (⌘W)",
                action: onClose
            )
            .opacity(isActive || isHovering ? 1 : 0)
            .allowsHitTesting(isActive || isHovering)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minWidth: 100, alignment: .leading)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.primary.opacity(0.12) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .opacity(isActive ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…", action: onBeginRename)
            if hasCustomName {
                Button("Reset Name", action: onResetName)
            }
            Divider()
            Button("Close Tab", action: onClose)
        }
    }
}

/// A small circular icon button with a native-feeling hover highlight.
private struct CircularIconButton: View {
    let systemName: String
    let diameter: CGFloat
    let iconSize: CGFloat
    var help: String = ""
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    private var backgroundOpacity: Double {
        if isActive { return 0.16 }
        return isHovering ? 0.12 : 0
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill((isActive ? Color.accentColor : Color.primary).opacity(backgroundOpacity))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : (isHovering ? Color.primary : Color.secondary))
        .help(help)
        .onHover { isHovering = $0 }
    }
}
