//
//  TerminalPaneView.swift
//  Kommando
//
//  SwiftUI wrapper that hosts a session's live LocalProcessTerminalView inside a
//  container NSView. The container indirection keeps the terminal view's superview
//  stable so SwiftUI re-renders never detach the running shell.
//

import SwiftUI
import AppKit

struct TerminalPaneView: NSViewRepresentable {
    let session: TerminalSession
    var isFocused: Bool = false

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(session.terminalView, to: container)
        session.startIfNeeded()
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if session.terminalView.superview !== nsView {
            attach(session.terminalView, to: nsView)
        }
        if isFocused {
            focusTerminal()
        }
    }

    private func attach(_ terminal: NSView, to container: NSView) {
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        // Inset the terminal text horizontally for breathing room, while the container
        // itself stays flush to the pane edges — this lets the command-block highlight
        // bleed past the text to the very edge (see updateBlockHighlight).
        let inset = KommandoTerminalView.horizontalContentInset
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        session.terminalView.forceRedraw()
    }

    private func focusTerminal() {
        DispatchQueue.main.async {
            guard let window = session.terminalView.window else { return }
            if window.firstResponder !== session.terminalView {
                window.makeFirstResponder(session.terminalView)
            }
        }
    }
}
