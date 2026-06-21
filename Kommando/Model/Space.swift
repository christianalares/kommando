//
//  Space.swift
//  Kommando
//
//  A Space is the parent of a set of tabs (each of which owns a pane tree). Spaces let a
//  window hold several independent workspaces — e.g. one per project — that you switch
//  between with the space chip in the title bar or the ⌘E switcher. Background spaces keep
//  their shells running, exactly like background tabs.
//

import SwiftUI

@MainActor
@Observable
final class Space: Identifiable {
    let id: String
    /// User-facing name; its first letter is shown in the title-bar chip.
    var name: String
    /// Accent color (hex) shown as the chip's badge/dot.
    var colorHex: String
    /// Optional per-space working directory; new tabs/panes open here when the focused pane
    /// has no directory to inherit.
    var defaultDirectory: String?
    var tabs: [Tab]
    var activeTabId: String

    init(
        id: String = UUID().uuidString,
        name: String,
        colorHex: String = SpacePalette.defaultHex,
        defaultDirectory: String? = nil,
        tabs: [Tab],
        activeTabId: String
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.defaultDirectory = defaultDirectory
        self.tabs = tabs
        self.activeTabId = activeTabId
    }

    convenience init(restoring snapshot: SpaceSnapshot) {
        let tabs = snapshot.tabs.map { Tab(restoring: $0) }
        let active = tabs.contains(where: { $0.id == snapshot.activeTabId })
            ? snapshot.activeTabId
            : (tabs.first?.id ?? "")
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            colorHex: snapshot.colorHex,
            defaultDirectory: snapshot.defaultDirectory,
            tabs: tabs,
            activeTabId: active
        )
    }

    /// The single uppercase glyph shown in the chip (first letter of the name, "?" if empty).
    var letter: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.first ?? "?").uppercased()
    }

    var color: Color {
        Color(hex: colorHex) ?? .accentColor
    }
}

/// A small, fixed palette so new spaces get distinct colors without a full color picker.
enum SpacePalette {
    static let colors: [String] = [
        "#4F8DFD", // blue
        "#34C759", // green
        "#FF9F0A", // orange
        "#FF375F", // pink
        "#BF5AF2", // purple
        "#5AC8FA", // teal
        "#FFD60A", // yellow
        "#8E8E93", // gray
    ]

    static let defaultHex = "#4F8DFD"

    /// Picks the palette color used by the fewest existing spaces, so adding spaces cycles
    /// through distinct colors before repeating.
    static func next(after existing: [String]) -> String {
        var counts: [String: Int] = [:]
        for hex in existing {
            counts[hex.lowercased(), default: 0] += 1
        }
        return colors.min { (counts[$0.lowercased()] ?? 0) < (counts[$1.lowercased()] ?? 0) } ?? defaultHex
    }
}

extension Color {
    /// Parses "#RRGGBB" / "RRGGBB" (and the 8-digit "#RRGGBBAA" variant). Returns nil on
    /// malformed input so callers can fall back to an accent color.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else {
            return nil
        }
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
