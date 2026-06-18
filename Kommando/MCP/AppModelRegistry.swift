//
//  AppModelRegistry.swift
//  Kommando
//
//  Tracks the live per-window `AppModel`s so cross-window features (the MCP control
//  server) can enumerate every tab/pane and resolve a session id back to the window
//  that owns it. References are weak so closing a window lets its model deallocate.
//

import AppKit

@MainActor
final class AppModelRegistry {
    static let shared = AppModelRegistry()

    private final class Entry {
        weak var model: AppModel?
        weak var window: NSWindow?
        init(model: AppModel, window: NSWindow?) {
            self.model = model
            self.window = window
        }
    }

    private var entries: [Entry] = []
    /// The model of the most recently key window; the default target when a tool call
    /// doesn't name a specific session.
    private weak var currentModel: AppModel?

    /// Registers a window's model (idempotent) and marks it current.
    func register(model: AppModel, window: NSWindow?) {
        prune()
        if let existing = entries.first(where: { $0.model === model }) {
            existing.window = window
        } else {
            entries.append(Entry(model: model, window: window))
        }
        currentModel = model
    }

    func unregister(model: AppModel) {
        entries.removeAll { $0.model == nil || $0.model === model }
        if currentModel === model {
            currentModel = entries.last?.model
        }
    }

    func setCurrent(_ model: AppModel) {
        currentModel = model
    }

    /// All live models in registration order, paired with their window (if still open).
    var all: [(model: AppModel, window: NSWindow?)] {
        prune()
        return entries.compactMap { entry in
            guard let model = entry.model else { return nil }
            return (model, entry.window)
        }
    }

    func current() -> AppModel? {
        currentModel ?? all.first?.model
    }

    func window(for model: AppModel) -> NSWindow? {
        entries.first { $0.model === model }?.window
    }

    private func prune() {
        entries.removeAll { $0.model == nil }
    }
}
