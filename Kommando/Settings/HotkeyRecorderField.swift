//
//  HotkeyRecorderField.swift
//  Kommando
//
//  A click-to-record hotkey field. Clicking arms a local key-event monitor (so it can
//  capture combinations that are also menu shortcuts); the next key combo is captured,
//  and Escape cancels recording without changing the binding.
//

import SwiftUI
import AppKit

struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var shortcut: KeyShortcut

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView(shortcut: shortcut)
        view.onChange = { newValue in shortcut = newValue }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        if !nsView.isRecording {
            nsView.shortcut = shortcut
        }
    }
}

final class HotkeyRecorderView: NSView {
    var shortcut: KeyShortcut {
        didSet { needsDisplay = true }
    }
    var onChange: ((KeyShortcut) -> Void)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }
    private var monitor: Any?

    init(shortcut: KeyShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 140, height: 24)
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape cancels
                self.stopRecording()
                return nil
            }
            if let captured = KeyShortcut(event: event) {
                self.shortcut = captured
                self.onChange?(captured)
                self.stopRecording()
            } else {
                NSSound.beep()
            }
            return nil // swallow the event while recording
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        } else {
            NSColor.controlColor.setFill()
        }
        path.fill()

        path.lineWidth = isRecording ? 1.5 : 1
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let isEmpty = shortcut.key.isEmpty
        let text: String
        if isRecording {
            text = "Type shortcut…"
        } else if isEmpty {
            text = "Click to record"
        } else {
            text = shortcut.display
        }
        let placeholderStyle = isRecording || isEmpty
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: placeholderStyle ? .regular : .medium),
            .foregroundColor: placeholderStyle ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let textRect = NSRect(
            x: frame.minX,
            y: frame.midY - textSize.height / 2,
            width: frame.width,
            height: textSize.height
        )
        attributed.draw(in: textRect)
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
