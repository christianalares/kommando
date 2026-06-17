//
//  PaneTreeView.swift
//  Kommando
//
//  Renders a tab's PaneNode tree as a FLAT, stably-identified set of leaf views whose
//  frames are computed from the split tree. Because each leaf keeps a stable SwiftUI
//  identity (its leaf id), splitting/closing only moves and resizes surviving panes
//  instead of re-creating (and re-parenting) their terminal views — which is what used
//  to leave panes blank until clicked.
//

import SwiftUI
import AppKit

struct PaneTreeView: View {
    let tab: Tab
    let model: AppModel

    private let dividerThickness: CGFloat = 6

    @State private var dragStart: [Double]?

    var body: some View {
        GeometryReader { geo in
            let result = PaneLayoutEngine.layout(
                tab.tree,
                in: CGRect(origin: .zero, size: geo.size),
                dividerThickness: dividerThickness
            )

            ZStack(alignment: .topLeading) {
                ForEach(result.leaves) { leaf in
                    PaneLeafView(leafId: leaf.id, kind: leaf.kind, tab: tab, model: model)
                        .frame(width: leaf.rect.width, height: leaf.rect.height)
                        .offset(x: leaf.rect.minX, y: leaf.rect.minY)
                }

                ForEach(result.dividers) { divider in
                    DividerHandle(axis: divider.axis)
                        .frame(width: divider.rect.width, height: divider.rect.height)
                        .offset(x: divider.rect.minX, y: divider.rect.minY)
                        .gesture(dividerGesture(divider))
                }

                if isContentDropActive,
                   let target = model.paneDropTarget,
                   let leaf = result.leaves.first(where: { $0.id == target.leafId }) {
                    dropHighlight(rect: leaf.rect, edge: target.edge)
                }
            }
            .onChange(of: model.dragLocation) {
                updateDropTarget(
                    leaves: result.leaves,
                    contentFrame: geo.frame(in: .global)
                )
            }
            .onChange(of: model.drag) {
                updateDropTarget(
                    leaves: result.leaves,
                    contentFrame: geo.frame(in: .global)
                )
            }
            .onChange(of: model.dragOverStrip) {
                updateDropTarget(
                    leaves: result.leaves,
                    contentFrame: geo.frame(in: .global)
                )
            }
        }
    }

    // MARK: - Drop targeting (tab → pane and pane → pane)

    /// A content drop is being targeted whenever something is being dragged over the pane
    /// area (a detached tab, or a pane that isn't currently over the strip).
    private var isContentDropActive: Bool {
        model.drag != nil && !model.dragOverStrip
    }

    @ViewBuilder
    private func dropHighlight(rect: CGRect, edge: PaneEdge) -> some View {
        let half = halfRect(rect, edge)
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            )
            .frame(width: half.width, height: half.height)
            .offset(x: half.minX, y: half.minY)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: edge)
    }

    private func updateDropTarget(leaves: [LeafFrame], contentFrame: CGRect) {
        guard isContentDropActive else {
            model.paneDropTarget = nil
            return
        }
        let local = CGPoint(
            x: model.dragLocation.x - contentFrame.minX,
            y: model.dragLocation.y - contentFrame.minY
        )
        // A pane can't be dropped onto itself.
        let excluded = model.draggedPaneLeafId
        guard let leaf = leaves.first(where: { $0.rect.contains(local) && $0.id != excluded }) else {
            model.paneDropTarget = nil
            return
        }
        let edge = edge(for: local, in: leaf.rect)
        let target = PaneDropTarget(leafId: leaf.id, edge: edge)
        if model.paneDropTarget != target {
            model.paneDropTarget = target
        }
    }

    private func edge(for point: CGPoint, in rect: CGRect) -> PaneEdge {
        let dx = (point.x - rect.midX) / max(rect.width, 1)
        let dy = (point.y - rect.midY) / max(rect.height, 1)
        if abs(dx) > abs(dy) {
            return dx < 0 ? .leading : .trailing
        }
        return dy < 0 ? .top : .bottom
    }

    private func halfRect(_ rect: CGRect, _ edge: PaneEdge) -> CGRect {
        switch edge {
        case .leading:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .trailing:
            return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom:
            return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    private func dividerGesture(_ divider: DividerFrame) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? divider.fractions
                if dragStart == nil {
                    dragStart = divider.fractions
                }
                let isHorizontal = divider.axis == .horizontal
                let translation = isHorizontal ? value.translation.width : value.translation.height
                let delta = Double(translation / max(divider.available, 1))
                let minFraction = 0.08

                var a = start[divider.index] + delta
                var b = start[divider.index + 1] - delta
                if a < minFraction {
                    b -= (minFraction - a)
                    a = minFraction
                }
                if b < minFraction {
                    a -= (minFraction - b)
                    b = minFraction
                }
                var updated = start
                updated[divider.index] = a
                updated[divider.index + 1] = b
                model.setFractions(tabId: tab.id, splitId: divider.splitId, fractions: updated)
            }
            .onEnded { _ in
                dragStart = nil
            }
    }
}

// MARK: - Layout engine

struct LeafFrame: Identifiable {
    let id: String
    let kind: PaneKind
    let rect: CGRect
}

struct DividerFrame: Identifiable {
    let id: String
    let splitId: String
    let index: Int
    let axis: SplitAxis
    let rect: CGRect
    let available: CGFloat
    let fractions: [Double]
}

struct PaneLayoutResult {
    var leaves: [LeafFrame] = []
    var dividers: [DividerFrame] = []
}

enum PaneLayoutEngine {
    static func layout(_ node: PaneNode, in rect: CGRect, dividerThickness: CGFloat) -> PaneLayoutResult {
        var result = PaneLayoutResult()
        place(node, in: rect, dividerThickness: dividerThickness, into: &result)
        return result
    }

    private static func place(_ node: PaneNode, in rect: CGRect, dividerThickness: CGFloat, into result: inout PaneLayoutResult) {
        switch node {
        case .leaf(let id, let kind):
            result.leaves.append(LeafFrame(id: id, kind: kind, rect: rect))

        case .split(let id, let axis, let children, let fractions):
            guard !children.isEmpty else { return }
            let isHorizontal = axis == .horizontal
            let total = isHorizontal ? rect.width : rect.height
            let dividerSpace = dividerThickness * CGFloat(max(0, children.count - 1))
            let available = max(0, total - dividerSpace)
            let safeFractions = normalized(fractions, count: children.count)

            var cursor = isHorizontal ? rect.minX : rect.minY
            for (index, child) in children.enumerated() {
                let length = CGFloat(safeFractions[index]) * available
                let childRect = isHorizontal
                    ? CGRect(x: cursor, y: rect.minY, width: length, height: rect.height)
                    : CGRect(x: rect.minX, y: cursor, width: rect.width, height: length)
                place(child, in: childRect, dividerThickness: dividerThickness, into: &result)
                cursor += length

                if index < children.count - 1 {
                    let dividerRect = isHorizontal
                        ? CGRect(x: cursor, y: rect.minY, width: dividerThickness, height: rect.height)
                        : CGRect(x: rect.minX, y: cursor, width: rect.width, height: dividerThickness)
                    result.dividers.append(
                        DividerFrame(
                            id: "\(id)#\(index)",
                            splitId: id,
                            index: index,
                            axis: axis,
                            rect: dividerRect,
                            available: available,
                            fractions: safeFractions
                        )
                    )
                    cursor += dividerThickness
                }
            }
        }
    }

    private static func normalized(_ fractions: [Double], count: Int) -> [Double] {
        guard fractions.count == count else {
            return Array(repeating: 1.0 / Double(count), count: count)
        }
        let sum = fractions.reduce(0, +)
        guard sum > 0 else {
            return Array(repeating: 1.0 / Double(count), count: count)
        }
        return fractions.map { $0 / sum }
    }
}

// MARK: - Divider handle

private struct DividerHandle: View {
    let axis: SplitAxis

    @State private var isHovering = false

    var body: some View {
        let isHorizontal = axis == .horizontal

        // A wide, transparent hit area for easy grabbing with a thin visible line that
        // brightens on hover so it's clear the line can be dragged.
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.primary.opacity(isHovering ? 0.45 : 0.12))
                .frame(
                    width: isHorizontal ? (isHovering ? 3 : 1) : nil,
                    height: isHorizontal ? nil : (isHovering ? 3 : 1)
                )
        }
        .contentShape(Rectangle())
        .pointerStyle(isHorizontal ? .columnResize : .rowResize)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Pane hover tracking

/// Transparent overlay that reports whether the cursor is over the pane. Uses an AppKit
/// tracking area (reliable even above the embedded terminal view, unlike SwiftUI's
/// `.onHover`) and returns `nil` from `hitTest` so all clicks fall through to the terminal.
private struct PaneHoverTracker: NSViewRepresentable {
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onHoverChange = { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {}

    final class TrackingNSView: NSView {
        var onHoverChange: ((Bool) -> Void)?
        private var trackingAreaRef: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChange?(false)
        }

        // Let every click pass straight through to the terminal beneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

// MARK: - Leaf

private struct PaneLeafView: View {
    let leafId: String
    let kind: PaneKind
    let tab: Tab
    let model: AppModel

    @State private var isHoveringHandle = false
    @State private var isHoveringPane = false

    private var isFocused: Bool {
        tab.focusedLeafId == leafId
    }

    private var isDimmed: Bool {
        !isFocused && tab.tree.leafIds.count > 1
    }

    /// A handle is only useful when the tab has more than one pane (so there's somewhere
    /// to rearrange to, or another pane to pop out from).
    private var showsHandle: Bool {
        tab.tree.leafIds.count > 1
    }

    private var isBeingDragged: Bool {
        model.draggedPaneLeafId == leafId
    }

    var body: some View {
        content
            // Dim inactive panes by fading their content, keeping the same background.
            .opacity(isDimmed ? 0.45 : 1)
            .clipped()
            // Reliable pane-hover detection that still lets clicks reach the terminal.
            .overlay { PaneHoverTracker(isHovering: $isHoveringPane) }
            .overlay(alignment: .topTrailing) { handleOverlay }
            // Fade the pane while it's the one being dragged (a floating preview follows
            // the cursor instead).
            .opacity(isBeingDragged ? 0.35 : 1)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                model.focusLeaf(leafId)
            })
            .onAppear(perform: wireTitleUpdates)
    }

    @ViewBuilder
    private var handleOverlay: some View {
        // Reveal on hover; keep it mounted while this pane is being dragged so the
        // in-flight gesture isn't cancelled when the cursor leaves the corner.
        if showsHandle && (isHoveringPane || isBeingDragged) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHoveringHandle ? Color.primary : .secondary)
                .frame(width: 22, height: 22)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                .padding(6)
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .pointerStyle(.grabIdle)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.12)) { isHoveringHandle = hovering }
                }
                .gesture(paneDragGesture)
                .help("Drag to move this pane — drop on another pane to rearrange, or on the tab bar to pop it out into its own tab")
                .transition(.opacity)
        }
    }

    private var paneDragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                model.drag = .pane(leafId: leafId)
                model.dragLocation = value.location
                model.dragOverStrip = model.stripFrame.contains(value.location)
            }
            .onEnded { _ in
                if model.dragOverStrip {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.movePaneToNewTab(leafId: leafId)
                    }
                } else if let target = model.paneDropTarget {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.movePane(leafId: leafId, to: target)
                    }
                }
                model.endDrag()
            }
    }

    /// Keep the tab's title in sync with this terminal's working directory while it's focused.
    private func wireTitleUpdates() {
        guard kind == .terminal else { return }
        let session = SessionRegistry.shared.terminalSession(for: leafId)
        session.onDirectoryChange = { [weak tab, weak model] _ in
            guard let tab, let model, tab.focusedLeafId == leafId else { return }
            model.refreshTabTitle(tab)
        }
        // When the shell exits (e.g. the user types `exit`), close its pane automatically.
        session.onProcessTerminated = { [weak model] _ in
            model?.closeLeaf(leafId)
        }
        if isFocused {
            model.refreshTabTitle(tab)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .terminal:
            TerminalPaneContainer(
                session: SessionRegistry.shared.terminalSession(for: leafId),
                isFocused: isFocused
            )
        case .repl:
            ReplPaneView(session: SessionRegistry.shared.replSession(for: leafId))
        }
    }
}
