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
            }
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

// MARK: - Leaf

private struct PaneLeafView: View {
    let leafId: String
    let kind: PaneKind
    let tab: Tab
    let model: AppModel

    private var isFocused: Bool {
        tab.focusedLeafId == leafId
    }

    private var isDimmed: Bool {
        !isFocused && tab.tree.leafIds.count > 1
    }

    var body: some View {
        content
            // Dim inactive panes by fading their content, keeping the same background.
            .opacity(isDimmed ? 0.45 : 1)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                model.focusLeaf(leafId)
            })
            .onAppear(perform: wireTitleUpdates)
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
