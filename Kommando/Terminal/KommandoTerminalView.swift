//
//  KommandoTerminalView.swift
//  Kommando
//
//  LocalProcessTerminalView subclass that notifies on output/scroll so the JSON
//  detector can re-scan the visible buffer. Notifications are debounced.
//

import AppKit
import SwiftTerm

final class KommandoTerminalView: LocalProcessTerminalView {
    var onContentChange: (() -> Void)?
    /// Supplies the shell's current working directory so relative paths can be resolved
    /// for ⌘-click link detection.
    var currentDirectoryProvider: (() -> String?)?

    private var rescanScheduled = false
    private var lastLaidOutSize: CGSize = .zero

    // MARK: - ⌘-click links
    private var commandHeld = false
    private var hoveredLink: TerminalLink?
    private var hoveredRow: Int?
    private let linkUnderline = LinkUnderlineView()

    private weak var cachedScroller: NSScroller?
    private var scrollerHideWork: DispatchWorkItem?

    private var terminalScroller: NSScroller? {
        if let cachedScroller {
            return cachedScroller
        }
        let found = subviews.compactMap { $0 as? NSScroller }.first
        cachedScroller = found
        return found
    }

    private func configureScroller() {
        guard let scroller = terminalScroller else { return }
        scroller.scrollerStyle = .overlay
        scroller.controlSize = .small
        scroller.knobStyle = .default
        scroller.alphaValue = 0 // hidden until the user scrolls
    }

    private func flashScroller() {
        guard let scroller = terminalScroller, scroller.isEnabled else { return }
        scrollerHideWork?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            scroller.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak scroller] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                scroller?.animator().alphaValue = 0
            }
        }
        scrollerHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    // When SwiftTerm's view is re-parented (split/close), AppKit resizes it but doesn't
    // always repaint, so the pane stays blank until it's clicked. Forcing a full redraw
    // whenever the laid-out size actually changes covers split, close, and resize.
    override func layout() {
        super.layout()
        if bounds.size != lastLaidOutSize {
            lastLaidOutSize = bounds.size
            forceRedraw()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        forceRedraw()
        configureScroller()
        installKeyMonitor()
        installMouseMonitor()
        if linkUnderline.superview == nil {
            linkUnderline.isHidden = true
            addSubview(linkUnderline)
        }
    }

    func forceRedraw() {
        let repaint = { [weak self] in
            guard let self, self.window != nil else { return }
            self.getTerminal().updateFullScreen()
            self.needsDisplay = true
        }
        DispatchQueue.main.async(execute: repaint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: repaint)
    }

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var wheelScrollAccumulator: CGFloat = 0

    // Native macOS text-navigation: ⌥← / ⌥→ move by word, ⌘← / ⌘→ jump to line start/end,
    // ⌥⌫ deletes the previous word, ⌘⌫ deletes to the line start. SwiftTerm's keyDown isn't
    // open for override, so we intercept via a local monitor while this view is first responder
    // and translate to the control sequences zsh's (emacs) line editor understands.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleNavigationKey(event) else { return event }
            return nil
        }
    }

    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard window != nil, window?.firstResponder === self else { return false }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.contains(.control), !flags.contains(.shift) else { return false }

        let command = flags.contains(.command)
        let option = flags.contains(.option)
        guard command != option else { return false }

        switch event.keyCode {
        case 123: // left arrow
            send(txt: command ? "\u{01}" : "\u{1b}b")   // Ctrl-A / ESC b
            return true
        case 124: // right arrow
            send(txt: command ? "\u{05}" : "\u{1b}f")   // Ctrl-E / ESC f
            return true
        case 51: // delete / backspace
            send(txt: command ? "\u{15}" : "\u{1b}\u{7f}") // Ctrl-U / ESC DEL
            return true
        default:
            return false
        }
    }

    // SwiftTerm already manages mouse tracking and an OSC-8 hyperlink preview while ⌘ is
    // held; we layer on detection of plain-text URLs and on-disk paths so those become
    // clickable too, with an underline + pointing-hand cursor as hover feedback. SwiftTerm's
    // mouse handlers aren't open for override, so (like the key handling above) we observe
    // via a local monitor while ⌘ is held.
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseUp, .flagsChanged, .scrollWheel]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMouse(event)
        }
    }

    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window != nil else { return event }

        switch event.type {
        case .flagsChanged:
            commandHeld = event.modifierFlags.contains(.command)
            if commandHeld {
                updateHoveredLink(at: currentMouseLocation())
            } else {
                clearHoveredLink()
            }
            return event
        case .mouseMoved:
            if event.modifierFlags.contains(.command) {
                updateHoveredLink(at: convert(event.locationInWindow, from: nil))
            } else {
                clearHoveredLink()
            }
            return event
        case .leftMouseUp:
            if event.modifierFlags.contains(.command),
               let link = link(at: convert(event.locationInWindow, from: nil)) {
                open(link)
                clearHoveredLink()
                return nil
            }
            return event
        case .scrollWheel:
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), allowMouseReporting, appWantsMouseReporting else {
                return event
            }
            forwardWheelEvent(event)
            return nil
        default:
            return event
        }
    }

    private func currentMouseLocation() -> CGPoint {
        guard let window else { return .zero }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// Maps a point in view coordinates to a detected link, skipping cells that already
    /// carry a SwiftTerm OSC-8 payload (those are handled by the framework itself).
    private func link(at point: CGPoint) -> TerminalLink? {
        guard let (row, col) = cell(at: point) else { return nil }
        let terminal = getTerminal()
        guard let line = terminal.getLine(row: row) else { return nil }
        if col < line.count, line[col].hasPayload {
            return nil
        }
        let text = line.translateToString(trimRight: false)
        return TerminalLinkDetector.link(in: text, atColumn: col, cwd: currentDirectoryProvider?())
    }

    private func updateHoveredLink(at point: CGPoint) {
        guard let (row, _) = cell(at: point), let link = link(at: point) else {
            clearHoveredLink()
            return
        }
        if link != hoveredLink || row != hoveredRow {
            hoveredLink = link
            hoveredRow = row
            positionUnderline(for: link, row: row)
        }
        NSCursor.pointingHand.set()
    }

    private func clearHoveredLink() {
        guard hoveredLink != nil else { return }
        hoveredLink = nil
        hoveredRow = nil
        linkUnderline.isHidden = true
        NSCursor.iBeam.set()
    }

    private func positionUnderline(for link: TerminalLink, row: Int) {
        let dim = cellDimensions()
        let width = CGFloat(link.endColumn - link.startColumn) * dim.width
        linkUnderline.strokeColor = nativeForegroundColor
        linkUnderline.frame = CGRect(
            x: CGFloat(link.startColumn) * dim.width,
            y: frame.height - CGFloat(row + 1) * dim.height,
            width: width,
            height: dim.height
        )
        linkUnderline.isHidden = false
        linkUnderline.needsDisplay = true
    }

    private func open(_ link: TerminalLink) {
        switch link.target {
        case .url(let url), .file(let url):
            NSWorkspace.shared.open(url)
        }
    }

    /// Converts a view-space point to a (screen row, column) cell, mirroring SwiftTerm's
    /// own hit-testing so highlights line up with what the user sees.
    private func cell(at point: CGPoint) -> (row: Int, col: Int)? {
        guard bounds.contains(point) else { return nil }
        let terminal = getTerminal()
        let dim = cellDimensions()
        guard dim.width > 0, dim.height > 0 else { return nil }
        let col = Int(point.x / dim.width)
        let row = Int((frame.height - point.y) / dim.height)
        guard row >= 0, row < terminal.rows, col >= 0, col < terminal.cols else { return nil }
        return (row, col)
    }

    /// Replicates SwiftTerm's font-derived cell metrics (it keeps them internal), so our
    /// hit-testing and underline placement match the rendered grid exactly.
    private func cellDimensions() -> (width: CGFloat, height: CGFloat) {
        let f = font
        let glyph = f.glyph(withName: "W")
        let width = f.advancement(forGlyph: glyph).width
        let height = ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
        return (max(1, width), max(1, height))
    }

    // MARK: - Mouse-wheel reporting
    //
    // SwiftTerm's own `scrollWheel` always drives local scrollback and never forwards wheel
    // notches to apps that requested mouse tracking (DECSET 1000/1002/1003), and it isn't
    // `open` so we can't override it. That breaks wheel scrolling inside full-screen TUIs
    // (vim, htop, less, Claude Code fullscreen). So — like the key handling above — we observe
    // scroll events via the local monitor: when the app under the cursor has enabled mouse
    // reporting we translate the wheel into xterm wheel button reports (Cb 64 = up, 65 = down)
    // and consume the event; otherwise we let SwiftTerm do its native scrollback.
    private var appWantsMouseReporting: Bool {
        switch getTerminal().mouseMode {
        case .off:
            return false
        default:
            return true
        }
    }

    private func forwardWheelEvent(_ event: NSEvent) {
        if event.phase.contains(.began) || event.momentumPhase.contains(.began) {
            wheelScrollAccumulator = 0
        }

        let dim = cellDimensions()
        let rawDelta: CGFloat
        if event.hasPreciseScrollingDeltas {
            // Trackpads: one report per row of travel feels natural.
            rawDelta = event.scrollingDeltaY / max(1, dim.height)
        } else if event.scrollingDeltaY != 0 {
            // Discrete wheels: a few reports per notch matches other terminals.
            rawDelta = event.scrollingDeltaY * 3
        } else {
            rawDelta = event.deltaY * 3
        }
        guard rawDelta != 0 else {
            return
        }

        wheelScrollAccumulator += rawDelta
        var steps = Int(wheelScrollAccumulator)
        guard steps != 0 else {
            return
        }
        wheelScrollAccumulator -= CGFloat(steps)

        let scrollingUp = steps > 0
        steps = min(abs(steps), 10) // cap bursts from fast flicks

        let terminal = getTerminal()
        let point = convert(event.locationInWindow, from: nil)
        let col = max(0, min(terminal.cols - 1, Int(point.x / dim.width)))
        let row = max(0, min(terminal.rows - 1, Int((frame.height - point.y) / dim.height)))

        let modifiers = event.modifierFlags
        var buttonFlags = scrollingUp ? 64 : 65
        if modifiers.contains(.shift) {
            buttonFlags += 4
        }
        if modifiers.contains(.option) {
            buttonFlags += 8
        }
        if modifiers.contains(.control) {
            buttonFlags += 16
        }

        for _ in 0..<steps {
            terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        clearHoveredLink()
        scheduleRescan()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        clearHoveredLink()
        scheduleRescan()
        flashScroller()
    }

    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.rescanScheduled = false
            self.onContentChange?()
        }
    }
}

/// A thin overlay that draws an underline beneath a ⌘-hovered link span.
private final class LinkUnderlineView: NSView {
    var strokeColor: NSColor = .labelColor

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let thickness: CGFloat = 1
        let y = max(thickness / 2, bounds.minY + thickness / 2)
        let path = NSBezierPath()
        path.lineWidth = thickness
        path.move(to: CGPoint(x: 0, y: y))
        path.line(to: CGPoint(x: bounds.width, y: y))
        strokeColor.setStroke()
        path.stroke()
    }
}
