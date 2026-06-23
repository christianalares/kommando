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
    /// Horizontal inset of the terminal text inside its pane container. The container is
    /// flush to the pane edges, so this is also how far the command-block highlight bleeds
    /// past the text to reach the edge. Applied in `TerminalPaneView.attach`.
    static let horizontalContentInset: CGFloat = 8

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

    // MARK: - Command blocks
    /// When on, OSC 133 marks are grouped into clickable command blocks. Toggled from
    /// settings via `TerminalSession.applyTheme()`.
    var commandBlocksEnabled = false {
        didSet {
            guard oldValue != commandBlocksEnabled else { return }
            if !commandBlocksEnabled {
                commandBlocks.removeAll()
                selectedBlockId = nil
                updateBlockHighlight()
            }
        }
    }
    private(set) var commandBlocks: [CommandBlock] = []
    private var selectedBlockId: UUID?
    private let blockHighlight = CommandBlockHighlightView()
    private let copyPill = CopyFeedbackPill()
    private var copyPillFadeWork: DispatchWorkItem?
    /// The selected block's frame in container coordinates, kept so the copy pill can be
    /// anchored to the block's top-right corner.
    private var lastBlockRect: CGRect?
    private var oscBlockHandlerRegistered = false
    private var mouseDownPoint: CGPoint?
    private var mouseDidDrag = false

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
        updateBlockHighlight()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        forceRedraw()
        configureScroller()
        installKeyMonitor()
        installMouseMonitor()
        registerCommandBlockHandlerIfNeeded()
        // The block highlight lives in the *container* (our superview), not in the terminal,
        // because SwiftTerm clips the terminal view to its bounds (macOS 14+). The container
        // is flush to the pane edges and doesn't clip, so the band can bleed past the inset
        // text to the edge. Re-add it on re-parent (split/close) and keep it above the
        // terminal so it overlays the text.
        if let container = superview, blockHighlight.superview !== container {
            blockHighlight.removeFromSuperview()
            blockHighlight.isHidden = true
            container.addSubview(blockHighlight)
        }
        // Keep the link underline above the block highlight.
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
            guard let self else { return event }
            if self.handleBlockCopy(event) {
                return nil
            }
            if self.handleBlockNavigation(event) {
                return nil
            }
            guard self.handleNavigationKey(event) else { return event }
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
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .scrollWheel]
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
        case .leftMouseDown:
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            mouseDidDrag = false
            return event
        case .leftMouseDragged:
            if let down = mouseDownPoint {
                let p = convert(event.locationInWindow, from: nil)
                if hypot(p.x - down.x, p.y - down.y) > 3 {
                    mouseDidDrag = true
                }
            }
            return event
        case .leftMouseUp:
            if event.modifierFlags.contains(.command),
               let link = link(at: convert(event.locationInWindow, from: nil)) {
                open(link)
                clearHoveredLink()
                return nil
            }
            handleBlockClick(event)
            mouseDownPoint = nil
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

    // MARK: - Command blocks

    /// Registers our OSC 133 (FinalTerm shell-integration) handler exactly once. SwiftTerm
    /// dispatches `dataReceived` (and therefore this handler) synchronously on the main
    /// thread, so it's safe to read the live cursor position here.
    private func registerCommandBlockHandlerIfNeeded() {
        guard !oscBlockHandlerRegistered else { return }
        oscBlockHandlerRegistered = true
        getTerminal().registerOscHandler(code: 133) { [weak self] data in
            MainActor.assumeIsolated {
                self?.handleCommandBlockMark(data)
            }
        }
    }

    /// Parses an OSC 133 payload (the bytes after `133;`): `A` prompt start, `B` command
    /// start, `C` output start, `D[;exit]` command end.
    private func handleCommandBlockMark(_ data: ArraySlice<UInt8>) {
        guard commandBlocksEnabled, let raw = String(bytes: data, encoding: .utf8) else { return }
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        guard let kind = parts.first else { return }
        switch kind {
        case "A":
            blockPromptStart()
        case "B":
            blockCommandStart()
        case "C":
            blockOutputStart()
        case "D":
            let exit = parts.count > 1 ? Int32(parts[1]) : nil
            blockCommandEnd(exit: exit)
        default:
            break
        }
    }

    private func currentCursor() -> (line: BufferLine?, row: Int, col: Int) {
        let terminal = getTerminal()
        let loc = terminal.getCursorLocation()
        return (terminal.getLine(row: loc.y), loc.y, loc.x)
    }

    private func blockPromptStart() {
        let terminal = getTerminal()
        let c = currentCursor()
        // Close the previous open block at the line just above this new prompt.
        if let idx = commandBlocks.lastIndex(where: { !$0.isFinished }) {
            if commandBlocks[idx].endLine == nil {
                commandBlocks[idx].endLine = terminal.getLine(row: max(0, c.row - 1))
            }
            commandBlocks[idx].isFinished = true
        }
        var block = CommandBlock()
        block.promptLine = c.line
        block.commandLine = c.line
        commandBlocks.append(block)
        pruneBlocks()
        updateBlockHighlight()
    }

    private func blockCommandStart() {
        let c = currentCursor()
        guard let idx = commandBlocks.indices.last else { return }
        commandBlocks[idx].commandLine = c.line
        commandBlocks[idx].commandStartCol = c.col
    }

    private func blockOutputStart() {
        guard let idx = commandBlocks.lastIndex(where: { !$0.isFinished }) else { return }
        commandBlocks[idx].ranCommand = true
        // The command line is stable now (typed + Enter pressed), so snapshot its text as
        // the block's integrity signature.
        commandBlocks[idx].commandSignature = lineSignature(commandBlocks[idx].commandLine)
        updateBlockHighlight()
    }

    /// The trimmed text a line currently renders, or nil if blank. Used both to snapshot a
    /// block's signature and to verify it later.
    private func lineSignature(_ line: BufferLine?) -> String? {
        guard let line else { return nil }
        let text = line.translateToString(trimRight: true).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func blockCommandEnd(exit: Int32?) {
        let terminal = getTerminal()
        let c = currentCursor()
        guard let idx = commandBlocks.lastIndex(where: { !$0.isFinished }) else { return }
        commandBlocks[idx].exitCode = exit
        // Tentative end at the last output line (the row above where the next prompt will
        // render). The following `A` confirms/refines this and marks the block finished.
        commandBlocks[idx].endLine = terminal.getLine(row: max(0, c.row - 1))
        updateBlockHighlight()
    }

    private func pruneBlocks() {
        // Drop blocks whose prompt line was trimmed from scrollback (weak ref niled out).
        commandBlocks.removeAll { $0.promptLine == nil }
        if commandBlocks.count > 500 {
            commandBlocks.removeFirst(commandBlocks.count - 500)
        }
        if let sel = selectedBlockId, !commandBlocks.contains(where: { $0.id == sel }) {
            selectedBlockId = nil
        }
    }

    /// Finds the on-screen row currently displaying `line`, by reference identity.
    private func screenRow(of line: BufferLine?) -> Int? {
        guard let line else { return nil }
        let terminal = getTerminal()
        for r in 0..<terminal.rows where terminal.getLine(row: r) === line {
            return r
        }
        return nil
    }

    /// The visible screen-row span a block currently occupies, clamped to the viewport, or
    /// nil if the block is stale or no part of it is currently visible.
    ///
    /// The bottom edge is derived from the *next* block's prompt line rather than from the
    /// block's own (recyclable) end line, so heights stay correct even after the scrollback
    /// has trimmed and reused line objects.
    private func visibleScreenRange(for block: CommandBlock) -> ClosedRange<Int>? {
        guard blockIsValid(block) else { return nil }
        let terminal = getTerminal()
        let rows = terminal.rows

        let promptScreen = screenRow(of: block.promptLine)

        // Bottom edge, in order of reliability.
        let endScreen: Int?
        if let nextPrompt = nextBlockPromptScreenRow(after: block) {
            // The next chronological block starts here; our block ends just above it.
            endScreen = nextPrompt - 1
        } else if !block.isFinished {
            // Live block with no successor yet: extend to the cursor.
            endScreen = terminal.getCursorLocation().y
        } else if let e = screenRow(of: block.endLine) {
            endScreen = e
        } else if promptScreen != nil {
            // Finished, last block, end scrolled below the viewport: extend to the bottom.
            endScreen = rows - 1
        } else {
            endScreen = nil
        }

        // Top edge: the prompt, or the top of the viewport if it scrolled above.
        let startScreen: Int?
        if let p = promptScreen {
            startScreen = p
        } else if endScreen != nil {
            startScreen = 0
        } else {
            startScreen = nil
        }

        guard let s = startScreen, let e0 = endScreen else { return nil }
        let lo = max(0, min(s, rows - 1))
        let hi = max(lo, min(e0, rows - 1))
        return lo...hi
    }

    /// Screen row of the first block after `block` (chronologically) whose prompt is
    /// currently visible — the boundary that caps `block`'s output region.
    private func nextBlockPromptScreenRow(after block: CommandBlock) -> Int? {
        guard let idx = commandBlocks.firstIndex(where: { $0.id == block.id }) else { return nil }
        let promptScreen = screenRow(of: block.promptLine)
        for i in (idx + 1)..<commandBlocks.count {
            guard let row = screenRow(of: commandBlocks[i].promptLine) else { continue }
            // Guard against identity confusion: a real successor renders below us.
            if let p = promptScreen, row <= p { continue }
            return row
        }
        return nil
    }

    /// Blocks that actually ran a command and remain intact — the only ones selectable.
    private var selectableBlocks: [CommandBlock] {
        commandBlocks.filter { $0.ranCommand && blockIsValid($0) }
    }

    /// True while the block's command line still renders the exact text it had when it ran.
    /// A failed match means the line was recycled (scrollback trim) or erased (`clear`), so
    /// the block no longer corresponds to anything on screen and must be ignored.
    private func blockIsValid(_ block: CommandBlock) -> Bool {
        guard let signature = block.commandSignature else { return false }
        return lineSignature(block.commandLine) == signature
    }

    private func block(atScreenRow row: Int) -> CommandBlock? {
        selectableBlocks.first { visibleScreenRange(for: $0)?.contains(row) ?? false }
    }

    private func handleBlockClick(_ event: NSEvent) {
        guard commandBlocksEnabled, !mouseDidDrag,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift) else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let (row, _) = cell(at: point) else {
            return
        }
        let hit = block(atScreenRow: row)
        // Toggle off when clicking the already-selected block; select otherwise; clicking
        // empty space (no block) clears the selection.
        if let hit, hit.id == selectedBlockId {
            selectedBlockId = nil
        } else {
            selectedBlockId = hit?.id
        }
        updateBlockHighlight()
    }

    /// Handles ⌘C when a block is selected and there's no active text selection.
    /// Only acts in the focused pane.
    private func handleBlockCopy(_ event: NSEvent) -> Bool {
        guard commandBlocksEnabled,
              window != nil, window?.firstResponder === self,
              selectedBlockId != nil,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "c" else {
            return false
        }
        // Defer to a real text selection when the user has one; only copy the block
        // otherwise (a plain click can leave an empty-but-active selection).
        if let selected = getSelection(), !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return copySelectedBlock()
    }

    /// Copies the selected block's command + output to the pasteboard.
    @discardableResult
    private func copySelectedBlock() -> Bool {
        guard let id = selectedBlockId,
              let block = commandBlocks.first(where: { $0.id == id }),
              let text = blockText(block) else {
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopyFeedback()
        return true
    }

    /// Briefly shows a "✓ Copied" pill at the selected block's top-right corner, fading it
    /// out shortly after. Re-copying restarts the animation.
    private func flashCopyFeedback() {
        guard let container = blockHighlight.superview, let rect = lastBlockRect else { return }
        if copyPill.superview !== container {
            copyPill.removeFromSuperview()
            container.addSubview(copyPill, positioned: .above, relativeTo: blockHighlight)
        } else {
            container.addSubview(copyPill, positioned: .above, relativeTo: blockHighlight)
        }

        let size = copyPill.pillSize
        // Top-right, tucked just inside the block (maxY is the top in this flipped-off view).
        let x = min(rect.maxX - size.width - 8, container.bounds.width - size.width - 4)
        let y = rect.maxY - size.height - 6
        copyPill.frame = CGRect(x: max(4, x), y: y, width: size.width, height: size.height)
        copyPill.needsDisplay = true
        copyPill.isHidden = false

        copyPillFadeWork?.cancel()
        copyPill.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            copyPill.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                self.copyPill.animator().alphaValue = 0
            }
        }
        copyPillFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let point = convert(event.locationInWindow, from: nil)

        // Right-clicking on a command block selects it and offers a block copy.
        if commandBlocksEnabled, let (row, _) = cell(at: point), let hit = block(atScreenRow: row) {
            selectedBlockId = hit.id
            updateBlockHighlight()
            let copyBlock = NSMenuItem(title: "Copy Command Block", action: #selector(copyBlockMenuAction), keyEquivalent: "")
            copyBlock.target = self
            menu.addItem(copyBlock)
            menu.addItem(.separator())
        }

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = self
        copyItem.isEnabled = selectionActive
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        pasteItem.target = self
        pasteItem.isEnabled = NSPasteboard.general.string(forType: .string) != nil
        menu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear", action: #selector(clearScreenAction), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        return menu
    }

    @objc private func copyBlockMenuAction() {
        copySelectedBlock()
    }

    @objc private func clearScreenAction() {
        send(txt: "\u{0c}") // Ctrl-L: clear screen, preserving any half-typed input.
    }

    /// ⌥↑ selects the previous (older) command block, ⌥↓ the next (newer) one, scrolling
    /// it into view if needed. Only acts in the focused pane.
    private func handleBlockNavigation(_ event: NSEvent) -> Bool {
        guard commandBlocksEnabled, window != nil, window?.firstResponder === self else {
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == [.option] else { return false }
        let up: Bool
        switch event.keyCode {
        case 126: up = true   // up arrow → older
        case 125: up = false  // down arrow → newer
        default: return false
        }

        let blocks = selectableBlocks
        guard !blocks.isEmpty else { return false }

        // Find the current selection's position among selectable blocks; if the current
        // selection isn't selectable (or nothing is selected), start from the most recent.
        let currentIndex = selectedBlockId.flatMap { id in
            blocks.firstIndex(where: { $0.id == id })
        }
        let newIndex: Int
        if let currentIndex {
            newIndex = up ? max(0, currentIndex - 1) : min(blocks.count - 1, currentIndex + 1)
        } else {
            newIndex = blocks.count - 1
        }
        selectedBlockId = blocks[newIndex].id
        revealSelectedBlock(preferUp: up)
        updateBlockHighlight()
        return true
    }

    /// Scrolls so the selected block is at least partly visible. Without public access to
    /// SwiftTerm's absolute scrollback coordinates we step in the cycling direction until
    /// the block's line identity reappears on screen (or we hit a scroll boundary).
    private func revealSelectedBlock(preferUp: Bool) {
        guard let id = selectedBlockId,
              let block = commandBlocks.first(where: { $0.id == id }) else {
            return
        }
        if visibleScreenRange(for: block) != nil {
            return
        }
        let step = max(1, getTerminal().rows - 2)
        var guardCount = 0
        while guardCount < 1000 {
            guardCount += 1
            let before = scrollPosition
            if preferUp {
                scrollUp(lines: step)
            } else {
                scrollDown(lines: step)
            }
            if visibleScreenRange(for: block) != nil {
                break
            }
            if scrollPosition == before {
                break // reached a scroll boundary
            }
        }
    }

    /// Extracts the command + output text for a block via `getText`, reusing the same
    /// visible row span the highlight draws so copy and highlight always agree.
    private func blockText(_ block: CommandBlock) -> String? {
        guard let range = visibleScreenRange(for: block) else { return nil }
        let terminal = getTerminal()
        let cols = terminal.cols
        let yDisp = terminal.buffer.yDisp

        // Skip the prompt decoration when the command line is the first visible row.
        let startCol = (screenRow(of: block.commandLine) == range.lowerBound) ? block.commandStartCol : 0

        let start = Position(col: max(0, startCol), row: range.lowerBound + yDisp)
        let end = Position(col: max(0, cols - 1), row: range.upperBound + yDisp)
        let text = terminal.getText(start: start, end: end)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Repositions (or hides) the highlight overlay for the selected block.
    private func updateBlockHighlight() {
        // Drop a selection whose backing line was recycled or erased (e.g. by `clear`) so we
        // never draw a phantom highlight over an unrelated region.
        if let id = selectedBlockId,
           let block = commandBlocks.first(where: { $0.id == id }),
           !blockIsValid(block) {
            selectedBlockId = nil
        }
        guard commandBlocksEnabled,
              let id = selectedBlockId,
              let block = commandBlocks.first(where: { $0.id == id }),
              let range = visibleScreenRange(for: block) else {
            blockHighlight.isHidden = true
            lastBlockRect = nil
            return
        }
        let dim = cellDimensions()
        let top = frame.height - CGFloat(range.lowerBound) * dim.height
        let bottom = frame.height - CGFloat(range.upperBound + 1) * dim.height
        // The band lives in the container (see viewDidMoveToWindow), which is flush to the
        // pane edges. The terminal is inset within it and vertically top-aligned, so the
        // row geometry maps straight across. We inset the band slightly from the container
        // edges (margin) and grow it a touch vertically (padding) so it reads as a rounded
        // card around the block rather than sitting flush against the edges/text.
        let hMargin: CGFloat = 4
        let vPad: CGFloat = 2
        let containerWidth = blockHighlight.superview?.bounds.width ?? frame.width
        let containerHeight = blockHighlight.superview?.bounds.height ?? frame.height
        var y = bottom - vPad
        var h = max(0, top - bottom) + vPad * 2
        if y < 0 { h += y; y = 0 }
        if y + h > containerHeight { h = containerHeight - y }
        let rect = CGRect(
            x: hMargin,
            y: y,
            width: max(0, containerWidth - hMargin * 2),
            height: max(0, h)
        )
        if let exit = block.exitCode {
            blockHighlight.accentBarColor = exit == 0
                ? NSColor.systemGreen.withAlphaComponent(0.8)
                : NSColor.systemRed.withAlphaComponent(0.8)
        } else {
            blockHighlight.accentBarColor = nil
        }
        // Keep the band above the terminal (a re-parent can re-add the terminal on top).
        if let container = blockHighlight.superview, container.subviews.last !== blockHighlight {
            container.addSubview(blockHighlight, positioned: .above, relativeTo: self)
        }
        blockHighlight.frame = rect
        blockHighlight.isHidden = false
        blockHighlight.needsDisplay = true
        lastBlockRect = rect
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
        updateBlockHighlight()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        clearHoveredLink()
        scheduleRescan()
        flashScroller()
        updateBlockHighlight()
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
