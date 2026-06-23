//
//  CustomPalette.swift
//  Kommando
//
//  A user-editable terminal color scheme: the 16 ANSI slots plus background,
//  foreground and cursor, stored as `#RRGGBB` hex strings so it round-trips
//  through JSON/UserDefaults and the Theme Studio's color wells.
//

import AppKit
import SwiftTerm

/// A named, user-editable terminal theme. `id` doubles as the value stored in
/// `SettingsStore.colorSchemeId` when this theme is the active scheme.
///
/// When `adaptsToAppearance` is on, `palette` is the dark variant and `lightPalette` is used
/// under a light macOS appearance; the active variant follows the system and swaps live.
struct CustomTheme: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var adaptsToAppearance: Bool
    var palette: CustomPalette
    var lightPalette: CustomPalette

    init(
        id: String = UUID().uuidString,
        name: String,
        adaptsToAppearance: Bool = false,
        palette: CustomPalette,
        lightPalette: CustomPalette? = nil
    ) {
        self.id = id
        self.name = name
        self.adaptsToAppearance = adaptsToAppearance
        self.palette = palette
        self.lightPalette = lightPalette ?? palette
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, adaptsToAppearance, palette, lightPalette
    }

    // Custom decode so themes saved before light/dark variants existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        palette = try c.decode(CustomPalette.self, forKey: .palette)
        adaptsToAppearance = try c.decodeIfPresent(Bool.self, forKey: .adaptsToAppearance) ?? false
        lightPalette = try c.decodeIfPresent(CustomPalette.self, forKey: .lightPalette) ?? palette
    }

    /// The palette to render for the given system appearance.
    func resolvedPalette(systemIsDark: Bool) -> CustomPalette {
        guard adaptsToAppearance else {
            return palette
        }
        return systemIsDark ? palette : lightPalette
    }
}

struct CustomPalette: Codable, Equatable {
    var background: String
    var foreground: String
    var cursor: String
    /// Exactly 16 entries: ANSI 0–7 (normal) followed by 8–15 (bright).
    var ansi: [String]

    /// Seeded from the macOS Terminal.app palette (SwiftTerm's shipped default) so a
    /// freshly-enabled custom theme looks familiar and legible before the user edits it.
    static let `default` = CustomPalette(
        background: "#282935",
        foreground: "#E5E9F0",
        cursor: "#89B4FA",
        ansi: [
            "#000000", "#C23621", "#25BC24", "#ADAD27",
            "#492EE1", "#D338D3", "#33BBC8", "#CBCCCD",
            "#818383", "#FC391F", "#31E722", "#EAEC23",
            "#5833FF", "#F935F8", "#14F0F0", "#E9EBEB",
        ]
    )

    /// A light-appearance starting point (light background/foreground, same ANSI as the
    /// default). Used to seed a theme's light variant when adaptation is first enabled.
    static let defaultLight = CustomPalette(
        background: "#F6F7FA",
        foreground: "#1C1C1E",
        cursor: "#1E66F5",
        ansi: CustomPalette.default.ansi
    )

    /// True when the chosen background reads as dark, used to drive the app chrome.
    var isDark: Bool {
        (NSColor(hexString: background) ?? .black).perceivedIsDark
    }

    /// 16 ANSI colors as SwiftTerm values, padding from the default if any entry is malformed.
    var ansiColors: [SwiftTerm.Color] {
        (0..<16).map { i in
            let hex = i < ansi.count ? ansi[i] : CustomPalette.default.ansi[i]
            return SwiftTerm.Color.fromHex(hex) ?? SwiftTerm.Color.fromHex(CustomPalette.default.ansi[i])!
        }
    }
}

extension NSColor {
    /// Parses `#RRGGBB` / `RRGGBB` into an sRGB color. Returns nil for malformed input.
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        guard s.count == 6, let value = UInt32(s, radix: 16) else {
            return nil
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    /// Uppercase `#RRGGBB` for display and storage.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded())
        )
    }

    /// Relative luminance test; below the midpoint we treat the color as "dark".
    var perceivedIsDark: Bool {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance < 0.5
    }
}

extension SwiftTerm.Color {
    /// Builds a SwiftTerm color (0...65535 channels) from a `#RRGGBB` hex string.
    static func fromHex(_ hex: String) -> SwiftTerm.Color? {
        guard let ns = NSColor(hexString: hex)?.usingColorSpace(.sRGB) else {
            return nil
        }
        return SwiftTerm.Color(
            red: UInt16((ns.redComponent * 65535).rounded()),
            green: UInt16((ns.greenComponent * 65535).rounded()),
            blue: UInt16((ns.blueComponent * 65535).rounded())
        )
    }
}
