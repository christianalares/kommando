//
//  Updater.swift
//  Kommando
//
//  Sparkle auto-update wiring. The app ships on the "beta" channel for now, so every
//  tester receives beta releases (and any stable releases, which carry no channel tag).
//

import Combine
import SwiftUI
import Sparkle

/// Controls which Sparkle channels the updater accepts. When beta updates are enabled the
/// app receives both beta-tagged and untagged (stable) releases; when disabled it receives
/// only untagged stable releases.
///
/// The flag is read straight from UserDefaults (not `SettingsStore`, which is main-actor
/// isolated) because Sparkle calls this from a nonisolated context. The key must match
/// `SettingsStore.Key.betaUpdatesEnabled`; it defaults to on while Kommando is pre-1.0.
final class BetaUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let betaEnabled = UserDefaults.standard.object(forKey: "betaUpdatesEnabled") as? Bool ?? true
        return betaEnabled ? ["beta"] : []
    }
}

/// Owns Sparkle's standard updater for the lifetime of the app. The delegate is held
/// strongly here because `SPUStandardUpdaterController` keeps only a weak reference.
final class AppUpdater {
    /// Single updater shared by the main scene and the Settings window.
    static let shared = AppUpdater()

    let controller: SPUStandardUpdaterController
    private let delegate = BetaUpdaterDelegate()

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

/// Two-way bridge between Sparkle's automatic-update preferences and SwiftUI toggles.
final class UpdaterSettingsViewModel: ObservableObject {
    private let updater: SPUUpdater

    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        // Assignments in init don't trigger didSet, so we just mirror current state.
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
}

/// Publishes whether a user-initiated update check is currently allowed, so the menu
/// item can enable/disable itself.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu item. An intermediate view is required for the
/// disabled state to update correctly inside a `CommandGroup`.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
