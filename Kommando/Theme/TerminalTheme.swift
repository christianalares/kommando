//
//  TerminalTheme.swift
//  Kommando
//
//  Built-in terminal color schemes and the applier that maps the user's settings onto
//  a live SwiftTerm view (font, palette, fg/bg, cursor color + style).
//

import AppKit
import SwiftTerm

struct TerminalThemeDef: Identifiable {
    let id: String
    let name: String
    /// Whether this is a dark scheme; drives the app chrome (window tint, SwiftUI color scheme).
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let ansi: [SwiftTerm.Color]
}

private extension SwiftTerm.Color {
    static func rgb(_ hex: UInt32) -> SwiftTerm.Color {
        let r = UInt16(((hex >> 16) & 0xff) * 257)
        let g = UInt16(((hex >> 8) & 0xff) * 257)
        let b = UInt16((hex & 0xff) * 257)
        return SwiftTerm.Color(red: r, green: g, blue: b)
    }
}

private extension NSColor {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

enum TerminalThemes {
    /// Tango-style 16-color ANSI palette used by the neutral schemes.
    private static let tango: [SwiftTerm.Color] = [
        .rgb(0x000000), .rgb(0xcc0000), .rgb(0x4e9a06), .rgb(0xc4a000),
        .rgb(0x3465a4), .rgb(0x75507b), .rgb(0x06989a), .rgb(0xd3d7cf),
        .rgb(0x555753), .rgb(0xef2929), .rgb(0x8ae234), .rgb(0xfce94f),
        .rgb(0x729fcf), .rgb(0xad7fa8), .rgb(0x34e2e2), .rgb(0xeeeeec),
    ]

    // Clear backgrounds let the window's vibrancy show through so the terminal sits
    // flush with the frame instead of reading as a black rectangle.
    static let dark = TerminalThemeDef(
        id: "dark",
        name: "Dark",
        isDark: true,
        background: .clear,
        foreground: .rgb(0xe5e9f0),
        cursor: .rgb(0x89b4fa),
        ansi: tango
    )

    static let light = TerminalThemeDef(
        id: "light",
        name: "Light",
        isDark: false,
        background: .clear,
        foreground: .rgb(0x1c1c1e),
        cursor: .rgb(0x1e66f5),
        ansi: tango
    )

    /// Schemes the user can pick (plus the special "system" option handled separately).
    static let selectable: [TerminalThemeDef] = [dark, light]

    static func byId(_ id: String) -> TerminalThemeDef? {
        selectable.first { $0.id == id }
    }

    static func resolved(schemeId: String) -> TerminalThemeDef {
        if schemeId == "system" {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        }
        return byId(schemeId) ?? dark
    }
}

enum TerminalTheming {
    @MainActor
    static func apply(_ settings: SettingsStore, to view: LocalProcessTerminalView) {
        let theme = TerminalThemes.resolved(schemeId: settings.colorSchemeId)

        view.font = resolveFont(name: settings.fontName, size: settings.fontSize)

        // Intentionally NOT calling installColors(): forcing a 16-color palette overrides
        // whatever colors the user's programs expect (e.g. zsh-autosuggestions' dark ANSI 8).
        // Leaving SwiftTerm's standard xterm palette in place keeps those colors legible and
        // matches what other terminals show.
        view.nativeForegroundColor = theme.foreground
        view.nativeBackgroundColor = theme.background
        view.caretColor = theme.cursor

        // SwiftTerm only uses nativeBackgroundColor for cell fills; the layer-backed view
        // keeps its own opaque layer background. Sync it so a clear/translucent theme
        // actually shows the window's vibrancy and sits flush with the frame.
        view.wantsLayer = true
        view.layer?.backgroundColor = theme.background.cgColor

        let swiftTermStyle = cursorStyle(settings.cursorStyle, blink: settings.cursorBlink)
        view.getTerminal().setCursorStyle(swiftTermStyle)
    }

    /// Resolves a font by PostScript name, then by family name (e.g. "MesloLGS NF"),
    /// falling back to the system monospaced font if the font isn't installed.
    private static func resolveFont(name: String, size: CGFloat) -> NSFont {
        if let font = NSFont(name: name, size: size) {
            return font
        }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: name) ?? []
        if let postScriptName = members.first?.first as? String,
           let font = NSFont(name: postScriptName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func cursorStyle(_ style: TerminalCursorStyle, blink: Bool) -> CursorStyle {
        switch style {
        case .block: return blink ? .blinkBlock : .steadyBlock
        case .bar: return blink ? .blinkBar : .steadyBar
        case .underline: return blink ? .blinkUnderline : .steadyUnderline
        }
    }
}
