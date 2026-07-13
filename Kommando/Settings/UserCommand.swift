//
//  UserCommand.swift
//  Kommando
//
//  A user-defined command: a shell snippet that runs in the focused terminal, optionally
//  bound to a keyboard shortcut. Managed in the Commands settings pane.
//

import Foundation

struct UserCommand: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var command: String
    var shortcut: KeyShortcut?
    /// When true the command is sent followed by Return; otherwise it's only inserted.
    var execute: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        command: String,
        shortcut: KeyShortcut? = nil,
        execute: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.shortcut = shortcut
        self.execute = execute
    }

    /// Display label used in menus; falls back to the command text if unnamed.
    var menuTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? command : trimmed
    }

    /// True when this is the untouched "Clear" command Kommando used to auto-seed (⌘K →
    /// `clear`). Used to migrate it away now that clearing is a built-in shortcut, while
    /// leaving any user-customized command alone.
    var matchesLegacyClearSeed: Bool {
        name == "Clear"
            && command == "clear"
            && execute
            && shortcut == KeyShortcut(key: "k", command: true)
    }
}
