//
//  TabBarView.swift
//  Kommando
//
//  Custom in-window tab strip. Each tab owns a pane tree; the active tab is highlighted.
//

import SwiftUI

struct TabBarView: View {
    let model: AppModel

    var body: some View {
        // Tabs scroll horizontally; the new-tab button stays pinned to the right so it's
        // always reachable. The ScrollView clips its content, so no tab is ever drawn
        // under the traffic lights (the viewport starts to their right via RootView's inset).
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.tabs) { tab in
                            TabChip(
                                title: tab.title,
                                kind: tab.tree.firstLeafKind,
                                isActive: tab.id == model.activeTabId,
                                onSelect: { model.selectTab(id: tab.id) },
                                onClose: { model.closeTab(id: tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.vertical, 2)
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

private struct TabChip: View {
    let title: String
    let kind: PaneKind
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private var iconName: String {
        kind == .repl ? "chevron.left.forwardslash.chevron.right" : "apple.terminal"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.green : Color.secondary)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

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
