//
//  SpaceSwitcherView.swift
//  Kommando
//
//  The space chip that sits between the traffic lights and the first tab, plus the popover
//  switcher it opens. Spaces are the parent of tabs/panes; the chip shows the active space's
//  first letter tinted with its color. ⌘E (or the menu) toggles the popover via a token.
//

import SwiftUI
import AppKit

struct SpaceChip: View {
    let model: AppModel
    @State private var showPopover = false

    var body: some View {
        let space = model.activeSpace
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(space?.letter ?? "D")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(space?.color ?? .accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.trailing, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Spaces (⌘E)")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            SpacesPopover(model: model, isPresented: $showPopover)
        }
        .onChange(of: model.spacesPopoverToken) {
            showPopover.toggle()
        }
    }
}

private struct SpacesPopover: View {
    let model: AppModel
    @Binding var isPresented: Bool

    @State private var renamingId: String?
    @State private var renameText = ""
    @State private var highlightedIndex = 0
    @FocusState private var renameFocused: Bool
    @FocusState private var listFocused: Bool

    /// Rows = one per space, plus a trailing "New Space" row. The keyboard cursor moves
    /// through all of them.
    private var newSpaceIndex: Int { model.spaces.count }
    private var rowCount: Int { model.spaces.count + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spaces")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 2)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                            row(for: space, index: index)
                                .id(index)
                        }

                        Divider().padding(.vertical, 2)

                        newSpaceRow
                            .id(newSpaceIndex)
                    }
                    .padding(2)
                }
                .frame(height: min(CGFloat(rowCount) * 34 + 16, 340))
                .onChange(of: highlightedIndex) { _, new in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onAppear {
            highlightedIndex = model.spaces.firstIndex { $0.id == model.activeSpaceId } ?? 0
            DispatchQueue.main.async { listFocused = true }
        }
        .onChange(of: model.spaces.count) {
            highlightedIndex = min(highlightedIndex, rowCount - 1)
        }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { activate() }
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) -> KeyPress.Result {
        guard renamingId == nil else { return .ignored }
        highlightedIndex = ((highlightedIndex + delta) % rowCount + rowCount) % rowCount
        return .handled
    }

    private func activate() -> KeyPress.Result {
        guard renamingId == nil else { return .ignored }
        if highlightedIndex == newSpaceIndex {
            createSpace()
        } else if model.spaces.indices.contains(highlightedIndex) {
            model.selectSpace(id: model.spaces[highlightedIndex].id)
            isPresented = false
        }
        return .handled
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for space: Space, index: Int) -> some View {
        let isActive = space.id == model.activeSpaceId
        let isHighlighted = index == highlightedIndex
        HStack(spacing: 8) {
            colorMenu(for: space)

            if renamingId == space.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($renameFocused)
                    .onSubmit { commitRename(space) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(space.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.20) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { if $0 { highlightedIndex = index } }
        .onTapGesture {
            guard renamingId != space.id else { return }
            highlightedIndex = index
            model.selectSpace(id: space.id)
            isPresented = false
        }
        .contextMenu { contextMenu(for: space, index: index) }
    }

    private var newSpaceRow: some View {
        let isHighlighted = highlightedIndex == newSpaceIndex
        return HStack(spacing: 8) {
            Color.clear.frame(width: 12)
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("New Space")
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.20) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { if $0 { highlightedIndex = newSpaceIndex } }
        .onTapGesture { createSpace() }
    }

    /// The space's color dot on the left. Clicking it opens a small palette to recolor the
    /// space. Non-focusable so picking a color doesn't steal keyboard focus from the list.
    private func colorMenu(for space: Space) -> some View {
        Menu {
            ForEach(SpacePalette.colors, id: \.self) { hex in
                let selected = space.colorHex.lowercased() == hex.lowercased()
                Button {
                    model.setSpaceColor(id: space.id, hex: hex)
                    listFocused = true
                } label: {
                    if selected {
                        Label(colorName(hex), systemImage: "checkmark")
                    } else {
                        Text(colorName(hex))
                    }
                }
            }
        } label: {
            Circle()
                .fill(space.color)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("Change color")
    }

    @ViewBuilder
    private func contextMenu(for space: Space, index: Int) -> some View {
        Button("Rename") { beginRename(space) }

        Button("Move Up") {
            model.moveSpace(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
        }
        .disabled(index == 0)

        Button("Move Down") {
            model.moveSpace(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
        }
        .disabled(index >= model.spaces.count - 1)

        Divider()

        Button("Set Folder…") { chooseFolder(for: space) }
        if space.defaultDirectory != nil {
            Button("Clear Folder") { model.setSpaceDirectory(id: space.id, directory: nil) }
        }

        Divider()

        Button("Delete Space", role: .destructive) {
            model.removeSpace(id: space.id)
        }
        .disabled(model.spaces.count <= 1)
    }

    // MARK: - Actions

    private func createSpace() {
        let space = model.newSpace()
        highlightedIndex = max(0, model.spaces.count - 1)
        beginRename(space)
    }

    private func beginRename(_ space: Space) {
        renameText = space.name
        renamingId = space.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ space: Space) {
        model.renameSpace(id: space.id, to: renameText)
        renamingId = nil
        DispatchQueue.main.async { listFocused = true }
    }

    private func cancelRename() {
        renamingId = nil
        DispatchQueue.main.async { listFocused = true }
    }

    private func chooseFolder(for space: Space) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Default folder for new tabs in this space"
        if let current = space.defaultDirectory {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.setSpaceDirectory(id: space.id, directory: url.path)
        }
    }

    private func colorName(_ hex: String) -> String {
        switch hex.lowercased() {
        case "#4f8dfd": return "Blue"
        case "#34c759": return "Green"
        case "#ff9f0a": return "Orange"
        case "#ff375f": return "Pink"
        case "#bf5af2": return "Purple"
        case "#5ac8fa": return "Teal"
        case "#ffd60a": return "Yellow"
        case "#8e8e93": return "Gray"
        default: return "Color"
        }
    }
}
