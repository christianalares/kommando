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

    /// Seeded on first launch so ⌘K clears the terminal out of the box.
    static let clearDefault = UserCommand(
        name: "Clear",
        command: "clear",
        shortcut: KeyShortcut(key: "k", command: true),
        execute: true
    )
}
