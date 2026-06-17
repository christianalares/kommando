//
//  TrafficLightConfigurator.swift
//  Kommando
//
//  Vertically centers the standard window buttons (traffic lights) within a taller
//  custom title bar. macOS pins them near the top by default, so for a tall tab bar we
//  reposition them and keep them centered across resizes / key changes.
//

import SwiftUI
import AppKit

struct TrafficLightConfigurator: NSViewRepresentable {
    let barHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.barHeight = barHeight
        context.coordinator.start(anchor: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.barHeight = barHeight
        context.coordinator.reposition()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var barHeight: CGFloat = 44
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func start(anchor: NSView, attempt: Int = 0) {
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self, let anchor else { return }
                guard let window = anchor.window else {
                    if attempt < 60 {
                        self.start(anchor: anchor, attempt: attempt + 1)
                    }
                    return
                }
                guard self.window == nil else { return }
                self.window = window

                let nc = NotificationCenter.default
                for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    self.observers.append(
                        nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                            self?.reposition()
                        }
                    )
                }

                // A few passes to beat AppKit's own button layout right after launch.
                for delay in [0.0, 0.05, 0.2, 0.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.reposition()
                    }
                }
            }
        }

        func reposition() {
            guard let window else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for type in types {
                guard let button = window.standardWindowButton(type),
                      let superview = button.superview else { continue }
                let targetY = superview.bounds.height - (barHeight / 2) - (button.frame.height / 2)
                if abs(button.frame.origin.y - targetY) > 0.5 {
                    button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: targetY))
                }
            }
        }
    }
}
