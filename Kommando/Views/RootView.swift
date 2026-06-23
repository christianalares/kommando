//
//  RootView.swift
//  Kommando
//
//  Hosts the tab bar and the active tab's pane tree over a translucent background.
//  Owns the per-window AppModel and publishes it as a focused scene value so menu
//  commands act on the frontmost window.
//

import SwiftUI

struct RootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var model = AppModel()
    @State private var isFullScreen = false
    @AppStorage("aiSidebarWidth") private var sidebarWidth: Double = 360

    private let titleBarHeight: CGFloat = 46
    private let minSidebarWidth: Double = 280
    private let maxSidebarWidth: Double = 720

    /// SwiftUI color scheme to force for the chrome. `nil` for "system" so the window
    /// tracks the OS appearance live (forcing a value here would lock it in place).
    private var preferredScheme: ColorScheme? {
        switch settings.colorSchemeId {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    /// Whether the active terminal theme is dark; drives the window tint so the chrome
    /// (tab bar, sidebar, dividers) matches the terminal.
    private var resolvedIsDark: Bool {
        if settings.colorSchemeId == "system" {
            return systemColorScheme == .dark
        }
        return TerminalThemes.resolved(schemeId: settings.colorSchemeId).isDark
    }

    /// Frosted-background tint: dark blue for dark themes, near-white for light themes.
    private var backgroundTint: Color {
        resolvedIsDark
            ? Color(red: 40 / 255, green: 41 / 255, blue: 53 / 255)
            : Color(red: 246 / 255, green: 247 / 255, blue: 250 / 255)
    }

    /// The window background: a solid theme color when the user opts out of transparency,
    /// otherwise the frosted vibrancy material tinted to match the terminal.
    @ViewBuilder
    private var chromeBackground: some View {
        if settings.reduceTransparency {
            backgroundTint.ignoresSafeArea()
        } else {
            ZStack {
                VisualEffectView(material: .underWindowBackground)
                backgroundTint.opacity(0.55)
            }
            .ignoresSafeArea()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn

            if model.chat.sidebarVisible {
                SidebarResizeHandle(
                    width: $sidebarWidth,
                    minWidth: minSidebarWidth,
                    maxWidth: maxSidebarWidth
                )
                AISidebarView(model: model)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .background {
            // Fill the whole window (including the 1px resize-handle seam) with the chrome
            // so no transparent gap shows the desktop through.
            chromeBackground
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay { tabDragPreview }
        .preferredColorScheme(preferredScheme)
        .background(WindowCloseHandler(model: model))
        .background(WindowFullScreenObserver(isFullScreen: $isFullScreen))
        .animation(.easeOut(duration: 0.2), value: isFullScreen)
        .environment(model)
        .focusedSceneValue(\.appModel, model)
        .onAppear { model.bootstrap() }
        .onChange(of: model.revision) {
            SessionPersistence.save(model.snapshotJSON())
        }
        .animation(.easeOut(duration: 0.2), value: model.chat.sidebarVisible)
        .animation(.easeOut(duration: 0.15), value: model.aiPromptVisible)
        .onChange(of: settings.revision) {
            SessionRegistry.shared.applyThemeToAll()
        }
        .onChange(of: systemColorScheme) {
            SessionRegistry.shared.applyThemeToAll()
        }
    }

    /// A small chip that follows the cursor while a tab or pane is dragged.
    @ViewBuilder
    private var tabDragPreview: some View {
        if let info = dragChipInfo() {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                let local = CGPoint(
                    x: model.dragLocation.x - origin.x,
                    y: model.dragLocation.y - origin.y
                )
                HStack(spacing: 6) {
                    Image(systemName: info.icon)
                        .font(.system(size: 11, weight: .medium))
                    Text(info.label)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.15))
                )
                .shadow(radius: 8, y: 2)
                .position(local)
                .opacity(0.95)
            }
            .allowsHitTesting(false)
        }
    }

    /// Icon + label for the floating drag chip, for whichever item is currently dragged.
    private func dragChipInfo() -> (icon: String, label: String)? {
        guard let drag = model.drag else { return nil }
        switch drag {
        case .tab(let id):
            guard let tab = model.tabs.first(where: { $0.id == id }) else { return nil }
            let icon = tab.tree.firstLeafKind == .repl
                ? "chevron.left.forwardslash.chevron.right"
                : "apple.terminal"
            return (icon, tab.displayTitle)
        case .pane(let leafId):
            let kind = model.activeTab?.tree.kind(of: leafId)
            let icon = kind == .repl
                ? "chevron.left.forwardslash.chevron.right"
                : "apple.terminal"
            let label = SessionRegistry.shared.existingTerminalSession(for: leafId)?.title
                ?? (kind == .repl ? "Inspector" : "Shell")
            return (icon, label)
        }
    }

    private var mainColumn: some View {
        ZStack(alignment: .topLeading) {
            chromeBackground
                .allowsHitTesting(false)

            if let tab = model.activeTab {
                PaneTreeView(tab: tab, model: model)
                    .id(tab.id)
                    .padding(.top, titleBarHeight + 1)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                TabBarView(model: model)
                    .frame(height: titleBarHeight)
                    // Reserve room for the traffic lights, except in fullscreen where macOS
                    // hides them — then the tabs slide left into that space.
                    .padding(.leading, isFullScreen ? 12 : 84)
                    .padding(.trailing, 8)
                Divider()
                    .opacity(0.4)
            }
            .background(TrafficLightConfigurator(barHeight: titleBarHeight))
            // The window is non-movable (so tab drags don't move it); this restores
            // window dragging from the empty title-bar background around the tabs.
            .background(WindowDragArea())

            if model.aiPromptVisible {
                VStack {
                    AIPromptOverlay(model: model)
                        .padding(.top, titleBarHeight + 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
    }
}

/// Invisible helper that fires `onClose` when its hosting window is about to close, so the
/// window's terminal sessions (PTYs/shell processes) can be torn down. Without this, closing
/// a window via the red traffic light would leak its running shells.
private struct WindowCloseHandler: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let model = self.model
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.observe(window, model: model)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var tokens: [NSObjectProtocol] = []

        func observe(_ window: NSWindow, model: AppModel) {
            guard tokens.isEmpty else { return }

            // Make the model reachable by the MCP control server, and keep "current"
            // pointed at whichever window is key.
            AppModelRegistry.shared.register(model: model, window: window)
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    AppModelRegistry.shared.setCurrent(model)
                }
            })

            tokens.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    AppModelRegistry.shared.unregister(model: model)
                    model.disposeAllSessions()
                }
            })
        }

        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }
}

/// Tracks whether the hosting window is in macOS fullscreen and publishes it back to the
/// view, so the tab bar can reclaim the traffic-light gap when the lights are hidden.
private struct WindowFullScreenObserver: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.observe(window) { value in
                isFullScreen = value
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var tokens: [NSObjectProtocol] = []

        func observe(_ window: NSWindow, update: @escaping (Bool) -> Void) {
            guard tokens.isEmpty else { return }
            update(window.styleMask.contains(.fullScreen))

            let nc = NotificationCenter.default
            tokens.append(
                nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { update(true) }
                }
            )
            tokens.append(
                nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { update(false) }
                }
            )
        }

        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }
}

/// A thin, draggable divider that resizes the AI sidebar (which sits to its right).
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double

    @State private var startWidth: Double?
    @State private var isHovering = false

    private var active: Bool { isHovering || startWidth != nil }

    var body: some View {
        // A hairline that lives in the layout flow (sits exactly on the seam, never over
        // content), with a wider transparent strip overlaid purely as the drag hit area.
        Rectangle()
            .fill(Color.primary.opacity(active ? 0.45 : 0.12))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let base = startWidth ?? width
                                if startWidth == nil { startWidth = width }
                                // Handle is left of the sidebar: dragging left widens it.
                                width = min(maxWidth, max(minWidth, base - value.translation.width))
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
