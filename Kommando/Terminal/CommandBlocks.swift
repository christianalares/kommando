//
//  CommandBlocks.swift
//  Kommando
//
//  "Command Blocks": groups terminal output between OSC 133 shell-integration marks
//  (FinalTerm protocol) into selectable units. Clicking a past command highlights its
//  whole region; ⌘C then copies the command and its output.
//
//  Blocks are anchored to `BufferLine` *identity* (a reference type that survives
//  scrolling) rather than absolute coordinates, because SwiftTerm doesn't publicly
//  expose the scroll-invariant origin (`linesTop`/`yBase`).
//
//  Identity alone isn't enough, though: when the scrollback fills up SwiftTerm *recycles*
//  the trimmed line objects (clears them in place and re-appends them at the bottom), so a
//  block's weak refs can silently start pointing at unrelated, refilled lines. To stay
//  correct, every block also carries a `commandSignature` (the text of its command line as
//  captured when it ran); a block is only treated as live while the line it points to still
//  renders that exact text. This single integrity check covers recycling, `clear` (ED2),
//  and any other in-place rewrite — no per-case special handling needed.
//

import AppKit
import SwiftTerm

/// One command + its output, delimited by OSC 133 `A` (prompt start) and the next
/// prompt (or `D`, command end).
struct CommandBlock: Identifiable {
    let id = UUID()
    /// The line carrying the shell prompt (`133;A`).
    weak var promptLine: BufferLine?
    /// The line where the typed command begins (`133;B`); usually the prompt line.
    weak var commandLine: BufferLine?
    /// The last line of the command's output. `nil` while the block is still open/running.
    weak var endLine: BufferLine?
    /// Column on `commandLine` where the typed command starts (after the prompt decoration).
    var commandStartCol: Int = 0
    /// The trimmed text of `commandLine` captured when the command ran. Used to detect when
    /// the underlying line has been recycled or cleared: if the line no longer renders this
    /// text, the block is stale and must not be selected or highlighted.
    var commandSignature: String?
    /// Exit status reported by `133;D;<code>`, if finished.
    var exitCode: Int32?
    /// True once a following prompt (or `D`) has closed the block.
    var isFinished: Bool = false
    /// True once a command actually executed (`133;C`). Distinguishes real command blocks
    /// from bare prompts (the current empty prompt, or empty-Enter presses), which should
    /// never be selectable.
    var ranCommand: Bool = false
}

/// A translucent overlay drawn on top of the terminal text for the selected block.
/// Rendered as a subtly inset rounded card so the underlying text stays readable, with a
/// status-tinted bar on the right edge (green = success, red = non-zero exit). The view is
/// positioned with a small margin/padding by `updateBlockHighlight`, so it never sits flush
/// against the pane edges or the command text.
final class CommandBlockHighlightView: NSView {
    var fillColor: NSColor = .controlAccentColor.withAlphaComponent(0.10)
    var borderColor: NSColor = .controlAccentColor.withAlphaComponent(0.45)
    var accentBarColor: NSColor?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 6
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fillColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        if let bar = accentBarColor {
            // Inset from the rounded right edge so it tucks inside the corners.
            let barRect = NSRect(x: rect.maxX - 4, y: rect.minY + 3, width: 2.5, height: rect.height - 6)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25)
            bar.setFill()
            barPath.fill()
        }
    }
}

/// A transient "✓ Copied" pill shown briefly after a command block is copied. Self-sizing
/// to its text + a small checkmark, with an accent background.
final class CopyFeedbackPill: NSView {
    private let label = "Copied"
    private let font = NSFont.systemFont(ofSize: 11, weight: .semibold)

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The size this pill wants, given its text and a checkmark glyph.
    var pillSize: CGSize {
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: ceil(textWidth) + 34, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: label, attributes: attrs)
        let textSize = text.size()

        var iconWidth: CGFloat = 0
        if let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
            iconWidth = check.size.width + 4
            let iconY = (rect.height - check.size.height) / 2
            let iconX = (rect.width - (iconWidth + textSize.width)) / 2
            check.isTemplate = true
            NSColor.white.set()
            let iconRect = NSRect(x: iconX, y: iconY, width: check.size.width, height: check.size.height)
            check.draw(in: iconRect)
        }

        let textX = (rect.width - (iconWidth + textSize.width)) / 2 + iconWidth
        let textY = (rect.height - textSize.height) / 2
        text.draw(at: CGPoint(x: textX, y: textY))
    }
}
