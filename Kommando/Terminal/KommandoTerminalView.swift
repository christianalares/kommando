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

    private var rescanScheduled = false
    private var lastLaidOutSize: CGSize = .zero

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

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        scheduleRescan()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
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
