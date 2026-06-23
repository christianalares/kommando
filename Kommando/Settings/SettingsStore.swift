//
//  SettingsStore.swift
//  Kommando
//
//  Central observable preferences. Plain values persist to UserDefaults; API keys live
//  in the Keychain. `revision` bumps on any change so views can re-apply terminal themes.
//

import SwiftUI

enum TerminalCursorStyle: String, CaseIterable, Codable, Identifiable {
    case block
    case bar
    case underline

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case anthropic
    case openai

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI"
        }
    }
    var keychainAccount: String { "apikey.\(rawValue)" }
}

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private enum Key {
        static let fontName = "fontName"
        static let fontSize = "fontSize"
        static let cursorStyle = "cursorStyle"
        static let cursorBlink = "cursorBlink"
        static let colorScheme = "colorScheme"
        static let reduceTransparency = "reduceTransparency"
        static let aiProvider = "aiProvider"
        static let shortcuts = "shortcutOverrides"
        static let userCommands = "userCommands"
        static let mcpServerEnabled = "mcpServerEnabled"
        static let commandBlocksEnabled = "commandBlocksEnabled"
        // NOTE: also read directly by BetaUpdaterDelegate in Updater.swift; keep in sync.
        static let betaUpdatesEnabled = "betaUpdatesEnabled"
    }

    /// Incremented on every change; observed to re-apply themes to live sessions.
    private(set) var revision = 0

    /// User overrides for keyboard shortcuts (action raw value -> shortcut). Missing
    /// entries fall back to `ShortcutAction.defaultShortcut`.
    private var shortcutOverrides: [String: KeyShortcut] = [:]

    /// User-defined commands runnable from the Commands menu / their hotkeys.
    var userCommands: [UserCommand] = [] { didSet { persistUserCommands(); bump() } }

    var fontName: String { didSet { persist(); bump() } }
    var fontSize: Double { didSet { persist(); bump() } }
    var cursorStyle: TerminalCursorStyle { didSet { persist(); bump() } }
    var cursorBlink: Bool { didSet { persist(); bump() } }
    var colorSchemeId: String { didSet { persist(); bump() } }
    /// When on, the terminal + window chrome paint a solid theme color instead of the
    /// translucent vibrancy material, so theme backgrounds can be matched pixel-exactly.
    var reduceTransparency: Bool { didSet { persist(); bump() } }
    var aiProvider: AIProvider { didSet { persist(); bump() } }
    /// When on, Kommando exposes a local MCP control socket so external AI tools can read
    /// and drive its terminals. Off by default. The socket lifecycle is owned by `MCPService`.
    var mcpServerEnabled: Bool { didSet { persist(); bump() } }
    /// When on, output between OSC 133 shell-integration marks is grouped into clickable
    /// "command blocks": click a past command to highlight it, then ⌘C to copy the command
    /// and its output. Only has a visible effect when the shell emits the marks.
    var commandBlocksEnabled: Bool { didSet { persist(); bump() } }
    /// When on, the updater accepts beta-channel releases (in addition to stable). On by
    /// default while Kommando is pre-1.0 and ships only on the beta channel. Read directly
    /// from UserDefaults by `BetaUpdaterDelegate` (which isn't main-actor isolated).
    var betaUpdatesEnabled: Bool { didSet { persist(); bump() } }

    private let defaults = UserDefaults.standard

    /// Default to a Nerd Font so shell prompts / `ls` icons render instead of tofu boxes.
    /// Falls back to the system monospaced font at render time if it isn't installed.
    static let defaultFontName = "MesloLGS NF"

    static let defaultFontSize: Double = 13
    static let minFontSize: Double = 8
    static let maxFontSize: Double = 32

    private init() {
        let storedFont = defaults.string(forKey: Key.fontName)
        // Migrate anyone still on the previous "SF Mono" default (which lacks icon glyphs).
        fontName = (storedFont == nil || storedFont == "SF Mono") ? Self.defaultFontName : storedFont!
        let size = defaults.double(forKey: Key.fontSize)
        fontSize = size > 0 ? size : Self.defaultFontSize
        cursorStyle = TerminalCursorStyle(rawValue: defaults.string(forKey: Key.cursorStyle) ?? "") ?? .block
        cursorBlink = defaults.object(forKey: Key.cursorBlink) as? Bool ?? true
        colorSchemeId = defaults.string(forKey: Key.colorScheme) ?? "system"
        reduceTransparency = defaults.object(forKey: Key.reduceTransparency) as? Bool ?? false
        aiProvider = AIProvider(rawValue: defaults.string(forKey: Key.aiProvider) ?? "") ?? .anthropic
        mcpServerEnabled = defaults.bool(forKey: Key.mcpServerEnabled)
        commandBlocksEnabled = defaults.object(forKey: Key.commandBlocksEnabled) as? Bool ?? true
        betaUpdatesEnabled = defaults.object(forKey: Key.betaUpdatesEnabled) as? Bool ?? true

        if let data = defaults.data(forKey: Key.shortcuts),
           let decoded = try? JSONDecoder().decode([String: KeyShortcut].self, from: data) {
            shortcutOverrides = decoded
        }

        if let data = defaults.data(forKey: Key.userCommands),
           let decoded = try? JSONDecoder().decode([UserCommand].self, from: data) {
            userCommands = decoded
        } else {
            // First launch: seed a sensible default (⌘K clears the terminal).
            userCommands = [.clearDefault]
            persistUserCommands()
        }
    }

    // MARK: - Keyboard shortcuts

    func shortcut(for action: ShortcutAction) -> KeyShortcut {
        _ = revision // establish observation dependency so menus re-read on change
        return shortcutOverrides[action.rawValue] ?? action.defaultShortcut
    }

    func isShortcutDefault(_ action: ShortcutAction) -> Bool {
        shortcutOverrides[action.rawValue] == nil
    }

    func setShortcut(_ shortcut: KeyShortcut, for action: ShortcutAction) {
        shortcutOverrides[action.rawValue] = shortcut
        persistShortcuts()
        bump()
    }

    func resetShortcut(for action: ShortcutAction) {
        shortcutOverrides[action.rawValue] = nil
        persistShortcuts()
        bump()
    }

    /// Returns the action currently bound to the same combination, if any (for conflict hints).
    func conflictingAction(for shortcut: KeyShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action
                && other.isScopedToChatInput == action.isScopedToChatInput
                && self.shortcut(for: other) == shortcut
        }
    }

    // MARK: - Font zoom

    func increaseFontSize() {
        fontSize = min(Self.maxFontSize, (fontSize + 1).rounded())
    }

    func decreaseFontSize() {
        fontSize = max(Self.minFontSize, (fontSize - 1).rounded())
    }

    func resetFontSize() {
        fontSize = Self.defaultFontSize
    }

    private func persistShortcuts() {
        if let data = try? JSONEncoder().encode(shortcutOverrides) {
            defaults.set(data, forKey: Key.shortcuts)
        }
    }

    // MARK: - User commands

    func addUserCommand() {
        userCommands.append(UserCommand(name: "", command: ""))
    }

    func deleteUserCommand(id: String) {
        userCommands.removeAll { $0.id == id }
    }

    /// Returns the name of an action or other command already bound to `shortcut`, if any.
    func commandShortcutConflict(for shortcut: KeyShortcut, excludingCommand id: String?) -> String? {
        if let action = ShortcutAction.allCases.first(where: {
            !$0.isScopedToChatInput && self.shortcut(for: $0) == shortcut
        }) {
            return action.title
        }
        if let other = userCommands.first(where: { $0.id != id && $0.shortcut == shortcut }) {
            return other.menuTitle.isEmpty ? "another command" : other.menuTitle
        }
        return nil
    }

    private func persistUserCommands() {
        if let data = try? JSONEncoder().encode(userCommands) {
            defaults.set(data, forKey: Key.userCommands)
        }
    }

    private func persist() {
        defaults.set(fontName, forKey: Key.fontName)
        defaults.set(fontSize, forKey: Key.fontSize)
        defaults.set(cursorStyle.rawValue, forKey: Key.cursorStyle)
        defaults.set(cursorBlink, forKey: Key.cursorBlink)
        defaults.set(colorSchemeId, forKey: Key.colorScheme)
        defaults.set(reduceTransparency, forKey: Key.reduceTransparency)
        defaults.set(aiProvider.rawValue, forKey: Key.aiProvider)
        defaults.set(mcpServerEnabled, forKey: Key.mcpServerEnabled)
        defaults.set(commandBlocksEnabled, forKey: Key.commandBlocksEnabled)
        defaults.set(betaUpdatesEnabled, forKey: Key.betaUpdatesEnabled)
    }

    private func bump() {
        revision += 1
    }

    // MARK: - API keys (Keychain)

    func apiKey(for provider: AIProvider) -> String? {
        Keychain.get(provider.keychainAccount)
    }

    func setAPIKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(provider.keychainAccount)
        } else {
            Keychain.set(trimmed, for: provider.keychainAccount)
        }
    }
}
