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
        .preferredColorScheme(preferredScheme)
        .background(WindowCloseHandler(model: model))
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

    private var mainColumn: some View {
        ZStack(alignment: .topLeading) {
            chromeBackground
                .allowsHitTesting(false)

            if let tab = model.activeTab {
                PaneTreeView(tab: tab, model: model)
                    .id(tab.id)
                    .padding(.top, titleBarHeight + 1)
                    .padding([.horizontal, .bottom], 8)
            }

            VStack(spacing: 0) {
                TabBarView(model: model)
                    .frame(height: titleBarHeight)
                    .padding(.leading, 84) // clear the traffic lights
                    .padding(.trailing, 8)
                Divider()
                    .opacity(0.4)
            }
            .background(TrafficLightConfigurator(barHeight: titleBarHeight))

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
        private var token: NSObjectProtocol?

        func observe(_ window: NSWindow, model: AppModel) {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    model.disposeAllSessions()
                }
            }
        }

        deinit {
            if let token {
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
