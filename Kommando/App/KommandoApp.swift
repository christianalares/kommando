//
//  KommandoApp.swift
//  Kommando
//
//  A native macOS terminal — Kommando.
//

import SwiftUI
import AppKit

@main
struct KommandoApp: App {
    @State private var settings = SettingsStore.shared
    private let updater = AppUpdater.shared

    init() {
        // Opt out of macOS automatic window tabbing so ⌘N always opens a real window,
        // regardless of the system "prefer tabs" setting.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Bring up the MCP control socket if the user has enabled it.
        MCPService.shared.syncWithSettings()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .frame(minWidth: 640, minHeight: 400)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater.updater)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
