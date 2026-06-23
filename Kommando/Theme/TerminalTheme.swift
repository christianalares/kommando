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
    /// Rendered cell background. `.clear` lets the window vibrancy show through (default look).
    let background: NSColor
    /// The opaque color the frosted background reads as. Used for OSC 10/11 theme reporting
    /// (so apps detect light/dark) and as the fill when "Reduce transparency" is on.
    let solidBackground: NSColor
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
        solidBackground: .rgb(0x282935),
        foreground: .rgb(0xe5e9f0),
        cursor: .rgb(0x89b4fa),
        ansi: tango
    )

    static let light = TerminalThemeDef(
        id: "light",
        name: "Light",
        isDark: false,
        background: .clear,
        solidBackground: .rgb(0xf6f7fa),
        foreground: .rgb(0x1c1c1e),
        cursor: .rgb(0x1e66f5),
        ansi: tango
    )

    /// Schemes the user can pick (plus the special "system" / "custom" options handled separately).
    static let selectable: [TerminalThemeDef] = [dark, light]

    /// The standard palette re-installed whenever the user is *not* on a custom theme, so
    /// turning custom colors off restores SwiftTerm's default ANSI colors mid-session. These
    /// hex values match SwiftTerm's shipped macOS Terminal.app palette, so for non-custom
    /// users this reproduces exactly what the terminal already showed.
    static let defaultAnsiColors: [SwiftTerm.Color] = CustomPalette.default.ansiColors

    static func byId(_ id: String) -> TerminalThemeDef? {
        selectable.first { $0.id == id }
    }

    /// Builds a theme definition from a user-editable palette.
    static func custom(_ palette: CustomPalette) -> TerminalThemeDef {
        TerminalThemeDef(
            id: "custom",
            name: "Custom",
            isDark: palette.isDark,
            background: .clear,
            solidBackground: NSColor(hexString: palette.background) ?? dark.solidBackground,
            foreground: NSColor(hexString: palette.foreground) ?? dark.foreground,
            cursor: NSColor(hexString: palette.cursor) ?? dark.cursor,
            ansi: palette.ansiColors
        )
    }

    @MainActor
    static func resolved(schemeId: String) -> TerminalThemeDef {
        if schemeId == "system" {
            return systemIsDark ? dark : light
        }
        if let theme = SettingsStore.shared.customTheme(id: schemeId) {
            return custom(theme.resolvedPalette(systemIsDark: systemIsDark))
        }
        return byId(schemeId) ?? dark
    }

    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

enum TerminalTheming {
    @MainActor
    static func apply(_ settings: SettingsStore, to view: LocalProcessTerminalView) {
        let theme = TerminalThemes.resolved(schemeId: settings.colorSchemeId)

        view.font = resolveFont(name: settings.fontName, size: settings.fontSize)

        // ANSI palette: only force the 16 colors when the user opts into a custom theme.
        // For built-in themes we re-install SwiftTerm's default palette (a no-op visually,
        // since it equals what the engine already had) so toggling *off* a custom theme
        // restores standard ANSI colors mid-session without forcing a palette on users who
        // rely on app-defined colors (e.g. zsh-autosuggestions' dim ANSI 8).
        if settings.isCustomScheme {
            view.installColors(theme.ansi)
        } else {
            view.installColors(TerminalThemes.defaultAnsiColors)
        }

        // Set the *terminal's* fg/bg to truthful opaque colors first. These drive OSC 10/11
        // color queries, so apps (e.g. Claude Code) can detect light vs. dark — independent of
        // how we actually render the background below. (Assigning these notifies SwiftTerm's
        // delegate, which also sets the native colors, so we override the native bg afterwards.)
        let terminal = view.getTerminal()
        terminal.foregroundColor = swiftTermColor(theme.foreground)
        terminal.backgroundColor = swiftTermColor(theme.solidBackground)

        // Rendered background: solid theme color when the user opts out of transparency,
        // otherwise `.clear` so the window's vibrancy shows through and the terminal sits
        // flush with the frame. SwiftTerm uses nativeBackgroundColor for cell fills; the
        // layer-backed view keeps its own opaque layer background, so sync both.
        let renderedBackground = settings.reduceTransparency ? theme.solidBackground : theme.background
        view.nativeForegroundColor = theme.foreground
        view.nativeBackgroundColor = renderedBackground
        view.caretColor = theme.cursor
        view.wantsLayer = true
        view.layer?.backgroundColor = renderedBackground.cgColor

        let swiftTermStyle = cursorStyle(settings.cursorStyle, blink: settings.cursorBlink)
        view.getTerminal().setCursorStyle(swiftTermStyle)
    }

    /// Converts an `NSColor` into SwiftTerm's 16-bit-per-channel `Color` for OSC reporting.
    private static func swiftTermColor(_ color: NSColor) -> SwiftTerm.Color {
        let c = color.usingColorSpace(.sRGB) ?? color
        return SwiftTerm.Color(
            red: UInt16(c.redComponent * 65535),
            green: UInt16(c.greenComponent * 65535),
            blue: UInt16(c.blueComponent * 65535)
        )
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
