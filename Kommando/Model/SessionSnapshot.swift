//
//  SessionSnapshot.swift
//  Kommando
//
//  Codable snapshot of a window's tabs/pane layout for session restore, plus a tiny
//  UserDefaults-backed persistence helper. Shell process state can't be restored, but the
//  layout and each terminal's working directory are, so reopening lands you where you left.
//

import Foundation

struct TabSnapshot: Codable {
    var id: String
    var title: String
    /// User-supplied name; optional so older saved sessions decode cleanly.
    var customTitle: String?
    var tree: PaneNode
    var focusedLeafId: String
}

struct SpaceSnapshot: Codable {
    var id: String
    var name: String
    var colorHex: String
    var defaultDirectory: String?
    var tabs: [TabSnapshot]
    var activeTabId: String
}

struct SessionSnapshot: Codable {
    /// The current (post-Spaces) layout. Optional so pre-Spaces saved sessions decode.
    var spaces: [SpaceSnapshot]?
    var activeSpaceId: String?
    /// Legacy pre-Spaces fields, kept optional purely for migration of old saved sessions.
    var tabs: [TabSnapshot]?
    var activeTabId: String?
    /// leaf id -> working directory, used to reopen terminals in the same folder.
    var directories: [String: String]

    /// Resolves the spaces to restore, migrating a legacy single-list snapshot by wrapping
    /// its tabs into one "Default" space so existing layouts survive the upgrade.
    func resolvedSpaces() -> [SpaceSnapshot] {
        if let spaces, !spaces.isEmpty {
            return spaces
        }
        guard let tabs, !tabs.isEmpty else { return [] }
        return [
            SpaceSnapshot(
                id: UUID().uuidString,
                name: "Default",
                colorHex: "#4F8DFD",
                defaultDirectory: nil,
                tabs: tabs,
                activeTabId: activeTabId ?? (tabs.first?.id ?? "")
            )
        ]
    }
}

enum SessionPersistence {
    private static let key = "kommando.session.v1"

    static func save(_ json: String) {
        UserDefaults.standard.set(json, forKey: key)
    }

    static func load() -> String? {
        guard let json = UserDefaults.standard.string(forKey: key), !json.isEmpty else {
            return nil
        }
        return json
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
