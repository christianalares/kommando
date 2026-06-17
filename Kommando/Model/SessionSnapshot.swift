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
    var tree: PaneNode
    var focusedLeafId: String
}

struct SessionSnapshot: Codable {
    var tabs: [TabSnapshot]
    var activeTabId: String
    /// leaf id -> working directory, used to reopen terminals in the same folder.
    var directories: [String: String]
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
