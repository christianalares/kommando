//
//  PaneNode.swift
//  Kommando
//
//  A recursive, Codable tree describing the split layout inside a tab. Mirrors the
//  PaneNode tree the Glaze app used, but as a native Swift enum.
//

import Foundation

enum PaneKind: String, Codable, Sendable {
    case terminal
    case repl
}

/// The axis along which a split's children are laid out.
/// `.horizontal` → children side by side (a vertical divider).
/// `.vertical`   → children stacked top to bottom (a horizontal divider).
enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// Which side of a pane another pane is being dropped onto.
enum PaneEdge {
    case leading
    case trailing
    case top
    case bottom
}

/// A resolved drop location: the pane being targeted and the edge to insert against.
struct PaneDropTarget: Equatable {
    let leafId: String
    let edge: PaneEdge
}

indirect enum PaneNode: Identifiable, Codable, Equatable {
    case leaf(id: String, kind: PaneKind)
    case split(id: String, axis: SplitAxis, children: [PaneNode], fractions: [Double])

    var id: String {
        switch self {
        case .leaf(let id, _): return id
        case .split(let id, _, _, _): return id
        }
    }

    static func newLeaf(_ kind: PaneKind) -> PaneNode {
        .leaf(id: UUID().uuidString, kind: kind)
    }

    var leafIds: [String] {
        switch self {
        case .leaf(let id, _):
            return [id]
        case .split(_, _, let children, _):
            return children.flatMap { $0.leafIds }
        }
    }

    var firstLeafId: String {
        switch self {
        case .leaf(let id, _):
            return id
        case .split(_, _, let children, _):
            return children.first?.firstLeafId ?? id
        }
    }

    var firstLeafKind: PaneKind {
        switch self {
        case .leaf(_, let kind):
            return kind
        case .split(_, _, let children, _):
            return children.first?.firstLeafKind ?? .terminal
        }
    }

    func kind(of leafId: String) -> PaneKind? {
        switch self {
        case .leaf(let id, let kind):
            return id == leafId ? kind : nil
        case .split(_, _, let children, _):
            for child in children {
                if let found = child.kind(of: leafId) {
                    return found
                }
            }
            return nil
        }
    }

    /// Returns the leaf id that follows `leafId` in depth-first order (wraps around).
    func leafId(after leafId: String) -> String? {
        let ids = leafIds
        guard let idx = ids.firstIndex(of: leafId), ids.count > 1 else { return nil }
        return ids[(idx + 1) % ids.count]
    }

    /// Splits `leafId` by inserting a new leaf alongside it.
    ///
    /// If the leaf already lives in a split along the *same* axis, the new pane is added
    /// as a sibling and every pane in that split is redistributed evenly (50/50 → 33/33/33).
    /// Otherwise the leaf is wrapped in a new perpendicular split (50/50).
    func splittingLeaf(_ leafId: String, axis: SplitAxis, newKind: PaneKind, newLeafId: String) -> PaneNode {
        switch self {
        case .leaf(let id, let kind):
            guard id == leafId else { return self }
            let original = PaneNode.leaf(id: id, kind: kind)
            let added = PaneNode.leaf(id: newLeafId, kind: newKind)
            return .split(id: UUID().uuidString, axis: axis, children: [original, added], fractions: [0.5, 0.5])
        case .split(let id, let axis2, let children, let fractions):
            // Same-axis split that directly contains the target: add a sibling, distribute evenly.
            if axis2 == axis,
               let idx = children.firstIndex(where: { $0.isLeaf(leafId) }) {
                var newChildren = children
                newChildren.insert(.leaf(id: newLeafId, kind: newKind), at: idx + 1)
                let even = Array(repeating: 1.0 / Double(newChildren.count), count: newChildren.count)
                return .split(id: id, axis: axis2, children: newChildren, fractions: even)
            }
            // Otherwise recurse; a matching leaf in a different-axis parent gets wrapped above.
            let newChildren = children.map {
                $0.splittingLeaf(leafId, axis: axis, newKind: newKind, newLeafId: newLeafId)
            }
            return .split(id: id, axis: axis2, children: newChildren, fractions: fractions)
        }
    }

    /// Inserts an entire subtree next to `leafId`, wrapping that leaf in a new split on the
    /// given edge. Used when a tab is dropped into the pane area to become a split.
    func inserting(_ subtree: PaneNode, nextTo leafId: String, edge: PaneEdge) -> PaneNode {
        switch self {
        case .leaf(let id, _):
            guard id == leafId else { return self }
            let axis: SplitAxis = (edge == .leading || edge == .trailing) ? .horizontal : .vertical
            let children: [PaneNode] = (edge == .leading || edge == .top)
                ? [subtree, self]
                : [self, subtree]
            return .split(id: UUID().uuidString, axis: axis, children: children, fractions: [0.5, 0.5])
        case .split(let id, let axis, let children, let fractions):
            let newChildren = children.map {
                $0.inserting(subtree, nextTo: leafId, edge: edge)
            }
            return .split(id: id, axis: axis, children: newChildren, fractions: fractions)
        }
    }

    /// True when this node is a leaf with the given id.
    private func isLeaf(_ leafId: String) -> Bool {
        if case .leaf(let id, _) = self {
            return id == leafId
        }
        return false
    }

    /// Remove a leaf, collapsing single-child splits. Returns nil if the subtree empties.
    func removingLeaf(_ leafId: String) -> PaneNode? {
        switch self {
        case .leaf(let id, _):
            return id == leafId ? nil : self
        case .split(let id, let axis, let children, let fractions):
            var keptChildren: [PaneNode] = []
            var keptFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removingLeaf(leafId) {
                    keptChildren.append(kept)
                    keptFractions.append(fraction)
                }
            }
            if keptChildren.isEmpty {
                return nil
            }
            if keptChildren.count == 1 {
                return keptChildren[0]
            }
            let sum = keptFractions.reduce(0, +)
            let normalized = sum > 0 ? keptFractions.map { $0 / sum } : keptChildren.map { _ in 1.0 / Double(keptChildren.count) }
            return .split(id: id, axis: axis, children: keptChildren, fractions: normalized)
        }
    }

    func settingFractions(splitId: String, fractions: [Double]) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let children, let existing):
            if id == splitId {
                return .split(id: id, axis: axis, children: children, fractions: fractions)
            }
            let newChildren = children.map { $0.settingFractions(splitId: splitId, fractions: fractions) }
            return .split(id: id, axis: axis, children: newChildren, fractions: existing)
        }
    }
}
