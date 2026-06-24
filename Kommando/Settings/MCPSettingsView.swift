//
//  MCPSettingsView.swift
//  Kommando
//
//  Settings pane for the built-in MCP server: a master toggle plus one-click setup for the
//  AI clients found on this machine, with copy-paste fallbacks for everything else.
//

import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    @State private var clients: [MCPClient] = []
    @State private var detecting = true

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.mcpServerEnabled },
            set: { MCPService.shared.setEnabled($0) }
        )
    }

    private var installed: [MCPClient] { clients.filter(\.isInstalled) }
    private var others: [MCPClient] { clients.filter { !$0.isInstalled } }

    var body: some View {
        Form {
            Section {
                Toggle("Enable MCP server", isOn: enabledBinding)
                if settings.mcpServerEnabled {
                    statusRow
                }
            } footer: {
                Text("Lets external AI tools read and control your terminals through the Model Context Protocol. While enabled, any connected tool can run commands in your terminals — only enable it for tools you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.mcpServerEnabled {
                if !MCPPaths.helperExists {
                    Section {
                        Label(
                            "The kommando-mcp helper isn't bundled in this build. Run scripts/build-mcp-helper.sh to build and install it.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else {
                    Section {
                        if detecting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Looking for installed AI tools…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if installed.isEmpty {
                            Text("No supported AI tools were found on this Mac. Use the snippets under “Other tools” to set one up manually.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(installed) { client in
                                ClientRow(client: client, onChanged: refresh)
                            }
                        }
                    } header: {
                        Text("Your AI tools")
                    }

                    OtherToolsSection(clients: others)

                    Section {
                        LabeledContent("Helper", value: MCPPaths.helperPath)
                        LabeledContent("Socket", value: MCPPaths.socketPath)
                    } footer: {
                        Text("Tools: list_terminals, read_terminal, write_terminal, send_control, create_terminal, split_pane, focus_terminal, close_terminal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(MCPService.shared.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(MCPService.shared.isRunning ? "Server running" : "Server stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        clients = await MCPClientInstaller.detect()
        detecting = false
    }

    private func refresh() {
        Task { clients = await MCPClientInstaller.detect() }
    }
}

// MARK: - Client icon

/// Shows the client's real app icon when we know its bundle path, falling back to an SF Symbol.
private struct ClientIcon: View {
    let client: MCPClient
    let size: CGFloat

    var body: some View {
        if let asset = client.logoAsset {
            Image(asset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else if let path = client.appIconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: client.symbol)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Installed client row

private struct ClientRow: View {
    let client: MCPClient
    let onChanged: () -> Void

    @State private var status: String?
    @State private var failed = false
    @State private var working = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ClientIcon(client: client, size: 18)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(client.name).fontWeight(.medium)
                        if client.isConfigured {
                            Label("Added", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2)
                                .foregroundStyle(.green)
                                .help(client.locallyTracked
                                    ? "Based on a local record of adding it from Kommando. Right-click to clear if you removed it in \(client.name)."
                                    : "")
                        }
                    }
                    Text(client.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                actionButtons
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(failed ? .red : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 32)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if client.locallyTracked && client.isConfigured {
                Button("Clear “Added” for \(client.name)") {
                    MCPClientInstaller.clearLocalConfirmation(client.id)
                    onChanged()
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if case .manual = client.primary {
            Button(copied ? "Copied!" : "Copy", action: copyConfig)
                .buttonStyle(.borderedProminent)
        } else {
            primaryButton
            Button(copied ? "Copied!" : "Copy", action: copyConfig)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        let label = Group {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Text(client.primaryLabel ?? (client.isConfigured ? "Re-add" : "Add"))
            }
        }
        // Already configured → quieter bordered style; first-time add → prominent.
        if client.isConfigured {
            Button(action: runPrimary) { label }
                .buttonStyle(.bordered)
                .disabled(working)
        } else {
            Button(action: runPrimary) { label }
                .buttonStyle(.borderedProminent)
                .disabled(working)
        }
    }

    private func copyConfig() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(client.copyText, forType: .string)
        status = client.copyHint
        failed = false
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func runPrimary() {
        working = true
        status = nil
        let action = client.primary
        Task.detached {
            let result: Result<String, Error>
            do {
                result = .success(try MCPClientInstaller.run(action))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                working = false
                switch result {
                case let .success(message):
                    failed = false
                    status = message
                    if client.locallyTracked {
                        MCPClientInstaller.markLocallyConfirmed(client.id)
                    }
                    onChanged()
                case let .failure(error):
                    failed = true
                    status = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Other (not-installed) tools

private struct OtherToolsSection: View {
    let clients: [MCPClient]
    @State private var copiedId: String?
    @State private var genericCopied = false

    private var genericJSON: String { MCPClientInstaller.clientConfigJSON(helperPath: MCPPaths.helperPath) }

    var body: some View {
        Section {
            DisclosureGroup("Other tools") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(clients) { client in
                        HStack(spacing: 10) {
                            ClientIcon(client: client, size: 16)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(client.name).font(.callout)
                                    if client.isConfigured {
                                        Label("Added", systemImage: "checkmark.circle.fill")
                                            .labelStyle(.titleAndIcon)
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
                                }
                                Text(client.copyHint)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(copiedId == client.id ? "Copied!" : "Copy") {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(client.copyText, forType: .string)
                                copiedId = client.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if copiedId == client.id { copiedId = nil }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    Text("Any other MCP client: add this block to its config. The helper finds its socket and token automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(genericJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

                    Button(genericCopied ? "Copied!" : "Copy configuration") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(genericJSON, forType: .string)
                        genericCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { genericCopied = false }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
