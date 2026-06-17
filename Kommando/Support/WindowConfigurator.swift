//
//  WindowConfigurator.swift
//  Kommando
//
//  Reaches the hosting NSWindow to enable a translucent, full-height-content look.
//

import SwiftUI
import AppKit

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            // The whole title bar would otherwise drag the window, which fights tab
            // reordering. We disable automatic moving and re-add it explicitly on the
            // empty title-bar background via `WindowDragArea` (performDrag).
            window.isMovable = false
            // Always open separate windows (never macOS native tabs), like iTerm.
            window.tabbingMode = .disallowed
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A background region that explicitly drags the window via `performDrag`. The window is
/// set non-movable (so dragging a tab reorders it instead of moving the window), so this
/// re-enables window dragging on the empty title-bar / tab-strip space.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else {
                super.mouseDown(with: event)
                return
            }
            // Double-click the title bar performs the system zoom, like a real title bar.
            if event.clickCount == 2 {
                window.performZoom(nil)
                return
            }
            window.performDrag(with: event)
        }
    }
}
