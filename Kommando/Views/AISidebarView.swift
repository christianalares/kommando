//
//  AISidebarView.swift
//  Kommando
//
//  The AI assistant sidebar: a streaming chat that always has the focused tab's context,
//  renders tool calls, and lets the user switch between / create conversations.
//

import SwiftUI

struct AISidebarView: View {
    let model: AppModel

    private var store: AIChatStore { model.chat }

    /// Matches RootView's tab bar height so the header lines up with the tabs.
    private let titleBarHeight: CGFloat = 46

    var body: some View {
        ZStack(alignment: .leading) {
            VisualEffectView(material: .sidebar)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                conversation
                composer
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .fixedSize()
            Text("Assistant")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
                .layoutPriority(1)

            Spacer(minLength: 8)

            chatSwitcher

            Button {
                store.newChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("New Chat")
            .fixedSize()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: titleBarHeight)
    }

    private var chatSwitcher: some View {
        Menu {
            ForEach(store.chats) { chat in
                Button {
                    store.selectChat(chat.id)
                } label: {
                    Label(chat.title, systemImage: chat.id == store.activeChatId ? "checkmark" : "bubble.left")
                }
            }
            Divider()
            if let active = store.activeChat, store.chats.count > 1 {
                Button(role: .destructive) {
                    store.deleteChat(active.id)
                } label: {
                    Label("Delete Current Chat", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(store.activeChat?.title ?? "New Chat")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .fixedSize()
            }
            .font(.system(size: 12))
            .frame(maxWidth: 160, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Conversation

    @ViewBuilder
    private var conversation: some View {
        if let chat = store.activeChat, !chat.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.messages) { message in
                            MessageRow(message: message, onInsert: model.insertCommandIntoFocusedTerminal)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(14)
                }
                .onChange(of: chat.messages.count) { scrollToBottom(proxy) }
                .onChange(of: chat.messages.last?.text) { scrollToBottom(proxy) }
                .onChange(of: store.activeChatId) { scrollToBottom(proxy, animated: false) }
                .onAppear { scrollToBottom(proxy, animated: false) }
            }
        } else {
            emptyState
        }
    }

    private let bottomAnchor = "chat-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text("Ask about your terminal")
                .font(.system(size: 14, weight: .semibold))
            Text("I can see this tab's output and working directory, suggest commands, and answer questions.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !store.hasAPIKey {
                noticeRow(icon: "key", text: "Add an API key in Settings to chat.")
            }
            ComposerField(store: store)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private func noticeRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
            Spacer()
            SettingsLink {
                Text("Open Settings")
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Composer field

private struct ComposerField: View {
    @Bindable var store: AIChatStore
    @State private var text = ""
    @State private var keyHandler = ScopedShortcutHandler()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $store.autoExecute) {
                Label("Auto-run generated commands", systemImage: "bolt.fill")
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(store.autoExecute ? Color.orange : Color.secondary)
            .help("When on, commands the assistant generates run in the terminal automatically instead of just being inserted.")

            inputRow
        }
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in
            // ⌘N (configurable) creates a new chat only while the input is focused,
            // intercepting it before the global New Window command.
            if isFocused {
                keyHandler.shortcut = SettingsStore.shared.shortcut(for: .newChat)
                keyHandler.onTrigger = {
                    store.newChat()
                    focused = true
                }
                keyHandler.start()
            } else {
                keyHandler.stop()
            }
        }
        .onDisappear { keyHandler.stop() }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this tab…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: 13))
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                .onSubmit(send)

            if store.isStreaming {
                Button(action: store.stop) {
                    Image(systemName: "stop.fill")
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? Color.accentColor : Color.gray.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send (⌘↩)")
            }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isStreaming
    }

    private func send() {
        guard canSend else { return }
        let prompt = text
        text = ""
        store.send(prompt)
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: ChatMessage
    let onInsert: (String) -> Void

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 32)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.22)))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.toolCalls) { call in
                    ToolCallView(call: call)
                }
                if !message.text.isEmpty {
                    AssistantContent(text: message.text, onInsert: onInsert)
                } else if message.isStreaming, message.toolCalls.isEmpty {
                    TypingIndicator()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tool call

private struct ToolCallView: View {
    let call: ToolCallRecord
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if !call.inputJSON.isEmpty, call.inputJSON != "{}" {
                    labeledBlock("Input", text: call.inputJSON)
                }
                if let result = call.result, !result.isEmpty {
                    labeledBlock("Result", text: result)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(call.displayName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if call.isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func labeledBlock(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.18)))
        }
    }
}

// MARK: - Assistant content (markdown + code blocks)

private struct AssistantContent: View {
    let text: String
    let onInsert: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownSegment.parse(text)) { segment in
                if segment.isCode {
                    CodeBlock(code: segment.content, onInsert: onInsert)
                } else {
                    Text(markdown(segment.content))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }
}

private struct CodeBlock: View {
    let code: String
    let onInsert: (String) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                Button {
                    onInsert(code)
                } label: {
                    Label("Insert", systemImage: "arrow.down.to.line")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Insert into terminal (not executed)")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider().opacity(0.3)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(animating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// MARK: - Scoped shortcut handler

/// Runs a closure when a specific shortcut is pressed while active, consuming the event
/// so it doesn't fall through to global menu commands (used to scope ⌘N to the chat input).
@MainActor
private final class ScopedShortcutHandler {
    var shortcut: KeyShortcut?
    var onTrigger: (() -> Void)?

    private var monitor: Any?

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let shortcut = self.shortcut,
                  let captured = KeyShortcut(event: event), captured == shortcut else {
                return event
            }
            self.onTrigger?()
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Lightweight markdown segmentation (splits fenced code blocks)

private struct MarkdownSegment: Identifiable {
    let id = UUID()
    let content: String
    let isCode: Bool

    static func parse(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var inCode = false
        var buffer: [String] = []

        func flush() {
            let joined = buffer.joined(separator: "\n")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(MarkdownSegment(content: inCode ? joined : trimmed, isCode: inCode))
            }
            buffer.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return segments
    }
}
