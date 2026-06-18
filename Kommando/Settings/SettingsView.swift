//
//  SettingsView.swift
//  Kommando
//
//  The native ⌘, Settings window: Appearance, Terminal, and AI sections.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            CommandsSettingsView()
                .tabItem { Label("Commands", systemImage: "command") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            MCPSettingsView()
                .tabItem { Label("MCP", systemImage: "network") }
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct AppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Theme", selection: $settings.colorSchemeId) {
                Text("System").tag("system")
                ForEach(TerminalThemes.selectable) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }

            Section {
                Toggle("Reduce transparency", isOn: $settings.reduceTransparency)
            } footer: {
                Text("Paint a solid background instead of the frosted material, so apps that draw their own colored blocks can match the terminal background exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TerminalSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    private let fontChoices = ["SF Mono", "Menlo", "Monaco", "Courier New", "Andale Mono"]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Font", selection: $settings.fontName) {
                ForEach(fontChoices, id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            Stepper(value: $settings.fontSize, in: 8...32, step: 1) {
                Text("Font size: \(Int(settings.fontSize)) pt")
            }

            Picker("Cursor", selection: $settings.cursorStyle) {
                ForEach(TerminalCursorStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }

            Toggle("Blink cursor", isOn: $settings.cursorBlink)
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in
                        ShortcutRow(action: action, settings: settings)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let settings: SettingsStore

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                if let hint = action.scopeHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)

            if let conflict = settings.conflictingAction(for: settings.shortcut(for: action), excluding: action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Also used by “\(conflict.title)”")
            }

            HotkeyRecorderField(shortcut: binding)
                .frame(width: 140, height: 24)

            Button {
                settings.resetShortcut(for: action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
            .disabled(settings.isShortcutDefault(action))
        }
    }

    private var binding: Binding<KeyShortcut> {
        Binding(
            get: { settings.shortcut(for: action) },
            set: { settings.setShortcut($0, for: action) }
        )
    }
}

private struct CommandsSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            if settings.userCommands.isEmpty {
                ContentUnavailableView(
                    "No Commands",
                    systemImage: "command",
                    description: Text("Add a command to run a shell snippet in the focused terminal, optionally bound to a hotkey.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($settings.userCommands) { $command in
                            CommandRow(command: $command, settings: settings)
                            Divider()
                        }
                    }
                    // Leave room so focus rings aren't clipped by the ScrollView's bounds.
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
            }

            HStack {
                Button {
                    settings.addUserCommand()
                } label: {
                    Label("Add Command", systemImage: "plus")
                }
                Spacer()
                Text("Commands appear in the Commands menu and run in the focused terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .frame(height: 460)
    }
}

private struct CommandRow: View {
    @Binding var command: UserCommand
    let settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: $command.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)

                TextField("command to run", text: $command.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Button(role: .destructive) {
                    settings.deleteUserCommand(id: command.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete command")
            }

            HStack(spacing: 10) {
                Toggle("Run immediately", isOn: $command.execute)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("When on, the command is executed (Return is sent). Otherwise it's only typed into the prompt.")

                Spacer(minLength: 12)

                if let shortcut = command.shortcut,
                   let conflict = settings.commandShortcutConflict(for: shortcut, excludingCommand: command.id) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Also used by “\(conflict)”")
                }

                HotkeyRecorderField(shortcut: shortcutBinding)
                    .frame(width: 130, height: 24)

                Button {
                    command.shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(command.shortcut == nil)
                .help("Clear shortcut")
            }
        }
    }

    private var shortcutBinding: Binding<KeyShortcut> {
        Binding(
            get: { command.shortcut ?? KeyShortcut(key: "") },
            set: { command.shortcut = $0.key.isEmpty ? nil : $0 }
        )
    }
}

private struct UpdatesSettingsView: View {
    @StateObject private var model = UpdaterSettingsViewModel(updater: AppUpdater.shared.updater)

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $model.automaticallyChecksForUpdates)
                Toggle("Automatically download updates", isOn: $model.automaticallyDownloadsUpdates)
                    .disabled(!model.automaticallyChecksForUpdates)

                Button("Check for Updates…") {
                    AppUpdater.shared.checkForUpdates()
                }
            } footer: {
                Text("Kommando is on the beta channel and updates are signed and verified before installing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var savedNotice: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            }

            Section("API Keys") {
                SecureField("Anthropic API key", text: $anthropicKey)
                SecureField("OpenAI API key", text: $openAIKey)

                HStack {
                    Button("Save Keys") {
                        settings.setAPIKey(anthropicKey, for: .anthropic)
                        settings.setAPIKey(openAIKey, for: .openai)
                        savedNotice = "Saved to Keychain."
                    }
                    if let savedNotice {
                        Text(savedNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            anthropicKey = settings.apiKey(for: .anthropic) ?? ""
            openAIKey = settings.apiKey(for: .openai) ?? ""
        }
    }
}
