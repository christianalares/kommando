//
//  ValueInspectorView.swift
//  Kommando
//
//  DevTools-style expandable tree for a JSONValue. `ValueTree` renders inline (no
//  scroll, for embedding in the REPL); `ValueInspectorView` wraps it in a scroll view
//  for the JSON inspector popover.
//

import SwiftUI

struct ValueInspectorView: View {
    private let root: JSONValue
    private let rootLabel: String

    init(root: JSONValue, rootLabel: String = "$0") {
        self.root = root
        self.rootLabel = rootLabel
    }

    var body: some View {
        ScrollView {
            ValueTree(root: root, rootLabel: rootLabel)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ValueTree: View {
    private let nodes: [InspectorNode]

    init(root: JSONValue, rootLabel: String = "$0") {
        nodes = [InspectorNode(label: rootLabel, value: root)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { node in
                NodeRow(node: node, depth: 0)
            }
        }
    }
}

private struct NodeRow: View {
    let node: InspectorNode
    let depth: Int

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if node.children != nil {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Spacer().frame(width: 10)
                }

                Text("\(node.label):")
                    .foregroundStyle(.secondary)
                Text(node.summary)
                    .foregroundStyle(color(for: node.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.leading, CGFloat(depth) * 12)

            if expanded, let children = node.children {
                ForEach(children) { child in
                    NodeRow(node: child, depth: depth + 1)
                }
            }
        }
        .onAppear {
            if depth == 0 {
                expanded = true
            }
        }
    }

    private func color(for kind: InspectorNode.Kind) -> Color {
        switch kind {
        case .object, .array: return .secondary
        case .string: return .green
        case .number: return .orange
        case .bool: return .purple
        case .null: return .pink
        }
    }
}
