//
//  AppCommands.swift
//  Kommando
//
//  Menu/keyboard commands. The configurable subset (tabs, panes, assistant) reads its
//  key bindings from SettingsStore so the Shortcuts settings pane can rebind them live.
//  Commands act on the frontmost window's AppModel via a focused scene value.
//

import SwiftUI

struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.appModel) private var model
    @State private var settings = SettingsStore.shared

    var body: some Commands {
        CommandGroup(after: .newItem) {
            shortcutButton("New Tab", .newTab) { $0.newTab() }
            shortcutButton("New Inspector Tab", .newInspectorTab) { $0.newTab(kind: .repl) }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                model?.closeFocused()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model == nil)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find…") {
                model?.showFindInFocusedPane()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model == nil)

            Button("Find Next") {
                model?.findNextInFocusedPane()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(model == nil)

            Button("Find Previous") {
                model?.findPreviousInFocusedPane()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(model == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Increase Font Size") { settings.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { settings.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { settings.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
        }

        CommandMenu("Assistant") {
            shortcutButton("Toggle AI Panel", .toggleAISidebar) { $0.chat.toggleSidebar() }

            // No global key equivalent: New Chat's shortcut (⌘N by default) is scoped to
            // the focused chat input so it doesn't clobber New Window.
            Button("New Chat") {
                model?.chat.sidebarVisible = true
                model?.chat.newChat()
            }
            .disabled(model == nil)
        }

        CommandMenu("Terminal") {
            shortcutButton("Generate Command…", .generateCommand) { $0.aiPromptVisible = true }

            Divider()

            shortcutButton("New Horizontal Pane", .splitRight) { $0.splitActive(axis: .horizontal) }
            shortcutButton("New Vertical Pane", .splitDown) { $0.splitActive(axis: .vertical) }
            shortcutButton("Zoom Pane", .zoomPane) { $0.toggleZoomFocused() }

            Divider()

            shortcutButton("Navigate Pane Left", .focusPaneLeft) { $0.focusPane(.left) }
            shortcutButton("Navigate Pane Right", .focusPaneRight) { $0.focusPane(.right) }
            shortcutButton("Navigate Pane Up", .focusPaneUp) { $0.focusPane(.up) }
            shortcutButton("Navigate Pane Down", .focusPaneDown) { $0.focusPane(.down) }

            Divider()

            shortcutButton("Previous Tab", .previousTab) { $0.cycleTab(-1) }
            shortcutButton("Next Tab", .nextTab) { $0.cycleTab(1) }

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button("Select Tab \(number)") {
                    model?.selectTab(index: number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled(model == nil)
            }
        }

        CommandMenu("Commands") {
            if settings.userCommands.isEmpty {
                Button("No Commands") {}
                    .disabled(true)
            } else {
                ForEach(settings.userCommands) { command in
                    commandButton(command)
                }
            }
        }
    }

    /// A menu button for a user-defined command, with its optional hotkey.
    @ViewBuilder
    private func commandButton(_ command: UserCommand) -> some View {
        let button = Button(command.menuTitle) {
            model?.runUserCommand(command)
        }
        .disabled(model == nil)

        if let shortcut = command.shortcut, shortcut.hasModifier, !shortcut.key.isEmpty {
            button.keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
        } else {
            button
        }
    }

    /// A menu button whose key binding is sourced from the user's shortcut settings.
    private func shortcutButton(
        _ title: String,
        _ action: ShortcutAction,
        perform: @escaping (AppModel) -> Void
    ) -> some View {
        let shortcut = settings.shortcut(for: action)
        return Button(title) {
            if let model { perform(model) }
        }
        .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
        .disabled(model == nil)
    }
}
