//
//  Shortcuts.swift
//  Kommando
//
//  User-configurable keyboard shortcuts: the set of bindable actions, a Codable key+
//  modifier representation, and conversions to SwiftUI's KeyEquivalent / EventModifiers
//  and to a display string (e.g. "⌘⌥⌃→").
//

import SwiftUI
import AppKit

/// An action the user can rebind in Settings.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTab
    case newInspectorTab
    case nextTab
    case previousTab
    case openSpaces
    case splitRight
    case splitDown
    case zoomPane
    case focusPaneRight
    case focusPaneLeft
    case focusPaneUp
    case focusPaneDown
    case clearTerminal
    case toggleAISidebar
    case newChat
    case generateCommand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .newInspectorTab: return "New Inspector Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .openSpaces: return "Show Spaces"
        case .splitRight: return "New Horizontal Pane"
        case .splitDown: return "New Vertical Pane"
        case .zoomPane: return "Zoom Pane"
        case .focusPaneRight: return "Navigate Pane Right"
        case .focusPaneLeft: return "Navigate Pane Left"
        case .focusPaneUp: return "Navigate Pane Up"
        case .focusPaneDown: return "Navigate Pane Down"
        case .clearTerminal: return "Clear Terminal"
        case .toggleAISidebar: return "Toggle AI Panel"
        case .newChat: return "New Chat"
        case .generateCommand: return "Generate Command"
        }
    }

    /// Whether this action only applies in a specific focus context rather than globally.
    var isScopedToChatInput: Bool {
        self == .newChat
    }

    var scopeHint: String? {
        isScopedToChatInput ? "When chat input is focused" : nil
    }

    /// Grouping used to lay the settings list out in sensible sections.
    enum Group: String, CaseIterable {
        case spaces = "Spaces"
        case tabs = "Tabs"
        case panes = "Panes"
        case terminal = "Terminal"
        case assistant = "Assistant"
    }

    var group: Group {
        switch self {
        case .openSpaces: return .spaces
        case .newTab, .newInspectorTab, .nextTab, .previousTab: return .tabs
        case .splitRight, .splitDown, .zoomPane,
             .focusPaneRight, .focusPaneLeft, .focusPaneUp, .focusPaneDown: return .panes
        case .clearTerminal: return .terminal
        case .toggleAISidebar, .newChat, .generateCommand: return .assistant
        }
    }

    var defaultShortcut: KeyShortcut {
        switch self {
        case .newTab:
            return KeyShortcut(key: "t", command: true)
        case .newInspectorTab:
            return KeyShortcut(key: "t", command: true, shift: true)
        case .nextTab:
            return KeyShortcut(key: KeyShortcut.rightArrowToken, command: true, option: true)
        case .previousTab:
            return KeyShortcut(key: KeyShortcut.leftArrowToken, command: true, option: true)
        case .openSpaces:
            return KeyShortcut(key: "e", command: true)
        case .splitRight:
            return KeyShortcut(key: "d", command: true)
        case .splitDown:
            return KeyShortcut(key: "d", command: true, shift: true)
        case .zoomPane:
            return KeyShortcut(key: KeyShortcut.returnToken, command: true, shift: true)
        case .focusPaneRight:
            return KeyShortcut(key: KeyShortcut.rightArrowToken, command: true, option: true, control: true)
        case .focusPaneLeft:
            return KeyShortcut(key: KeyShortcut.leftArrowToken, command: true, option: true, control: true)
        case .focusPaneUp:
            return KeyShortcut(key: KeyShortcut.upArrowToken, command: true, option: true, control: true)
        case .focusPaneDown:
            return KeyShortcut(key: KeyShortcut.downArrowToken, command: true, option: true, control: true)
        case .clearTerminal:
            return KeyShortcut(key: "k", command: true)
        case .toggleAISidebar:
            return KeyShortcut(key: "i", command: true)
        case .newChat:
            return KeyShortcut(key: "n", command: true)
        case .generateCommand:
            return KeyShortcut(key: KeyShortcut.returnToken, control: true)
        }
    }
}

/// A persisted keyboard shortcut. `key` is a single lowercased character or one of the
/// arrow tokens below.
struct KeyShortcut: Codable, Equatable {
    var key: String
    var command: Bool
    var option: Bool
    var control: Bool
    var shift: Bool

    init(key: String, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false) {
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    static let upArrowToken = "↑"
    static let downArrowToken = "↓"
    static let leftArrowToken = "←"
    static let rightArrowToken = "→"
    static let returnToken = "↩"

    var hasModifier: Bool { command || option || control || shift }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        if shift { modifiers.insert(.shift) }
        return modifiers
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case Self.upArrowToken: return .upArrow
        case Self.downArrowToken: return .downArrow
        case Self.leftArrowToken: return .leftArrow
        case Self.rightArrowToken: return .rightArrow
        case Self.returnToken: return .return
        default: return KeyEquivalent(key.first ?? "?")
        }
    }

    /// Human-readable glyph string, e.g. "⌘⌥⌃→".
    var display: String {
        var result = ""
        if control { result += "⌃" }
        if option { result += "⌥" }
        if shift { result += "⇧" }
        if command { result += "⌘" }
        result += keyGlyph
        return result
    }

    private var keyGlyph: String {
        switch key {
        case Self.upArrowToken, Self.downArrowToken, Self.leftArrowToken, Self.rightArrowToken, Self.returnToken:
            return key
        case " ":
            return "Space"
        default:
            return key.uppercased()
        }
    }

    /// Builds a shortcut from a captured key event, or nil if it isn't bindable.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)

        let key: String
        switch event.keyCode {
        case 123: key = Self.leftArrowToken
        case 124: key = Self.rightArrowToken
        case 125: key = Self.downArrowToken
        case 126: key = Self.upArrowToken
        case 36, 76: key = Self.returnToken // Return and keypad Enter
        default:
            guard let characters = event.charactersIgnoringModifiers, let first = characters.first else {
                return nil
            }
            let lowered = String(first).lowercased()
            // Reject control characters / empties (e.g. lone modifier presses).
            guard !lowered.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
            key = lowered
        }

        self.init(key: key, command: command, option: option, control: control, shift: shift)
    }
}
