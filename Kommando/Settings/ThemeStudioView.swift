//
//  ThemeStudioView.swift
//  Kommando
//
//  The "Theme Studio" window: manage a library of named custom themes (create, duplicate,
//  rename, delete) and edit each one's 16 ANSI colors plus background, foreground and cursor
//  as color wells / hex fields, with a deterministic live preview that exercises every slot
//  so legibility problems (e.g. washed-out yellow) are obvious immediately.
//

import SwiftUI

struct ThemeStudioView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selectedThemeId: String?

    var body: some View {
        HStack(spacing: 0) {
            themeRail
                .frame(width: 200)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear(perform: selectInitialTheme)
    }

    private func selectInitialTheme() {
        if let id = selectedThemeId, settings.customTheme(id: id) != nil {
            return
        }
        selectedThemeId = settings.customTheme(id: settings.colorSchemeId)?.id
            ?? settings.customThemes.first?.id
    }

    // MARK: - Theme rail

    private var themeRail: some View {
        VStack(spacing: 0) {
            List(selection: $selectedThemeId) {
                ForEach(settings.customThemes) { theme in
                    ThemeRailRow(theme: theme, isActive: settings.colorSchemeId == theme.id)
                        .tag(theme.id)
                        .contextMenu {
                            Button("Duplicate") {
                                selectedThemeId = settings.duplicateCustomTheme(id: theme.id)
                            }
                            Button("Delete", role: .destructive) {
                                settings.deleteCustomTheme(id: theme.id)
                            }
                        }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 4) {
                Button {
                    selectedThemeId = settings.addCustomTheme()
                } label: {
                    Image(systemName: "plus")
                }
                .help("New theme")

                Button {
                    if let id = selectedThemeId {
                        settings.deleteCustomTheme(id: id)
                        selectedThemeId = settings.customThemes.first?.id
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .help("Delete selected theme")
                .disabled(selectedThemeId == nil)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedThemeId, settings.customTheme(id: id) != nil {
            ThemeEditorPane(themeId: id)
        } else {
            ContentUnavailableView {
                Label("No Custom Themes", systemImage: "paintpalette")
            } description: {
                Text("Create a theme to customize the 16 ANSI colors, background, foreground and cursor.")
            } actions: {
                Button("Create Theme") {
                    selectedThemeId = settings.addCustomTheme()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct ThemeRailRow: View {
    let theme: CustomTheme
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            swatch
            Text(theme.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Active in terminals")
            }
        }
    }

    /// A tiny strip previewing the background plus a few accent colors.
    private var swatch: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(nsColor: NSColor(hexString: theme.palette.background) ?? .black))
            .frame(width: 28, height: 18)
            .overlay(
                HStack(spacing: 1) {
                    ForEach([1, 2, 4], id: \.self) { i in
                        Circle()
                            .fill(Color(nsColor: NSColor(hexString: theme.palette.ansi[i]) ?? .gray))
                            .frame(width: 4, height: 4)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15))
            )
    }
}

// MARK: - Editor pane (one theme)

private struct ThemeEditorPane: View {
    @Environment(SettingsStore.self) private var settings
    let themeId: String
    @State private var editingDarkVariant = true

    private var isActive: Bool { settings.colorSchemeId == themeId }
    private var themeIndex: Int? { settings.customThemes.firstIndex { $0.id == themeId } }
    private var adaptive: Bool { settings.customTheme(id: themeId)?.adaptsToAppearance ?? false }
    /// Which palette the editor currently writes to. Non-adaptive themes only have the one.
    private var editingDark: Bool { adaptive ? editingDarkVariant : true }
    private var variantKeyPath: WritableKeyPath<CustomTheme, CustomPalette> {
        editingDark ? \CustomTheme.palette : \CustomTheme.lightPalette
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            variantBar
            Divider()
            if let theme = settings.customTheme(id: themeId) {
                HStack(spacing: 0) {
                    editor
                        .frame(width: 320)
                    Divider()
                    ThemePreview(palette: theme[keyPath: variantKeyPath])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Theme name", text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .frame(maxWidth: 220)

            Spacer()

            Button("Reset", role: .destructive) {
                settings.resetCustomTheme(id: themeId)
            }
            .help("Restore this theme to the default palettes")

            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else {
                Button("Use in Terminals") {
                    settings.colorSchemeId = themeId
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var variantBar: some View {
        HStack(spacing: 12) {
            Toggle("Adapt to light & dark", isOn: adaptBinding)
                .help("Use separate palettes for light and dark; follows the system appearance.")
            Spacer()
            if adaptive {
                Picker("", selection: $editingDarkVariant) {
                    Text("Dark").tag(true)
                    Text("Light").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var adaptBinding: Binding<Bool> {
        Binding(
            get: { settings.customTheme(id: themeId)?.adaptsToAppearance ?? false },
            set: { settings.setThemeAdaptive(id: themeId, $0) }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { settings.customTheme(id: themeId)?.name ?? "" },
            set: { newValue in
                guard let index = themeIndex else { return }
                settings.customThemes[index].name = newValue
            }
        )
    }

    // MARK: Swatch editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                swatchSection("Window", rows: [
                    ("Background", \.background),
                    ("Foreground", \.foreground),
                    ("Cursor", \.cursor),
                ])
                ansiGrid
            }
            .padding(16)
        }
    }

    /// The 16 ANSI colors as 8 hue rows × Normal (0–7) / Bright (8–15) columns — more compact
    /// than two stacked lists of 8.
    private var ansiGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANSI COLORS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("Normal").font(.caption).foregroundStyle(.secondary)
                    Text("Bright").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<8, id: \.self) { i in
                    GridRow {
                        Text(ansiName(i))
                            .frame(width: 70, alignment: .leading)
                        ColorPicker("", selection: colorBinding(\.ansi[i]), supportsOpacity: false)
                            .labelsHidden()
                        ColorPicker("", selection: colorBinding(\.ansi[i + 8]), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private func swatchSection(
        _ title: String,
        rows: [(String, WritableKeyPath<CustomPalette, String>)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { label, keyPath in
                SwatchRow(
                    label: label,
                    color: colorBinding(keyPath),
                    hex: hexBinding(keyPath)
                )
            }
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<CustomPalette, String>) -> Binding<Color> {
        Binding(
            get: {
                let hex = settings.customTheme(id: themeId)?[keyPath: variantKeyPath][keyPath: keyPath] ?? "#000000"
                return Color(nsColor: NSColor(hexString: hex) ?? .black)
            },
            set: { newColor in
                writeColor(NSColor(newColor).hexString, to: keyPath)
            }
        )
    }

    private func hexBinding(_ keyPath: WritableKeyPath<CustomPalette, String>) -> Binding<String> {
        Binding(
            get: { settings.customTheme(id: themeId)?[keyPath: variantKeyPath][keyPath: keyPath] ?? "" },
            set: { newValue in
                // Only commit once it parses, so half-typed hex doesn't blank the swatch.
                guard NSColor(hexString: newValue) != nil else { return }
                writeColor(newValue.uppercased(), to: keyPath)
            }
        )
    }

    private func writeColor(_ hex: String, to keyPath: WritableKeyPath<CustomPalette, String>) {
        guard let index = themeIndex else {
            return
        }
        var palette = settings.customThemes[index][keyPath: variantKeyPath]
        palette[keyPath: keyPath] = hex
        settings.customThemes[index][keyPath: variantKeyPath] = palette
    }

    private func ansiName(_ i: Int) -> String {
        let base = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        return base[i % 8]
    }
}

private struct SwatchRow: View {
    let label: String
    @Binding var color: Color
    @Binding var hex: String

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36)
            Text(label)
                .frame(width: 90, alignment: .leading)
            TextField("#RRGGBB", text: $hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 100)
        }
    }
}

// MARK: - Preview

private struct ThemePreview: View {
    let palette: CustomPalette

    private func ansi(_ i: Int) -> Color {
        Color(nsColor: NSColor(hexString: palette.ansi[i]) ?? .gray)
    }
    private var fg: Color { Color(nsColor: NSColor(hexString: palette.foreground) ?? .white) }
    private var bg: Color { Color(nsColor: NSColor(hexString: palette.background) ?? .black) }
    private var cursor: Color { Color(nsColor: NSColor(hexString: palette.cursor) ?? .white) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                terminalSample
                swatchGrid
            }
            .padding(16)
        }
        .background(bg)
    }

    /// Builds one terminal line from colored segments, kept as a helper so the SwiftUI
    /// type-checker doesn't choke on long `Text + Text` chains.
    private func line(_ segments: [(String, Color)]) -> Text {
        segments.reduce(Text("")) { acc, segment in
            acc + Text(segment.0).foregroundColor(segment.1)
        }
    }

    private var terminalSample: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Prompt
            line([
                ("krille", ansi(2)), ("@", fg), ("mac", ansi(2)),
                (" ~/dev/kommando ", ansi(4)),
                ("git:(", fg), ("main", ansi(1)), (") ", fg), ("▏", cursor),
            ])

            // ls --color
            line([
                ("src  ", ansi(4)), ("build  ", ansi(4)), ("run.sh  ", ansi(2)),
                ("README.md  ", fg), ("notes.txt", fg),
            ])

            // git log — the reporter's pain: yellow refs/hashes on light backgrounds
            line([
                ("a1b2c3d", ansi(3)), (" (", fg), ("HEAD -> ", ansi(6)),
                ("main", ansi(2)), (") ", fg), ("Add custom ANSI palette", fg),
            ])

            // syntax-highlighted-ish line
            line([
                ("const ", ansi(5)), ("answer ", fg), ("= ", ansi(6)),
                ("\"42\"", ansi(3)), (";", fg),
            ])

            // dim / autosuggestion (bright black, ANSI 8)
            line([("git push --set-upstream origin main", ansi(8))])
        }
        .font(.system(.callout, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var swatchGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ANSI 0–15")
                .font(.caption2.weight(.semibold))
                .foregroundColor(fg.opacity(0.7))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(0..<16, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ansi(i))
                        .frame(height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(fg.opacity(0.12))
                        )
                        .overlay(
                            Text("\(i)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(i == 0 || (i >= 1 && i <= 6) ? .white.opacity(0.85) : .black.opacity(0.7))
                        )
                }
            }
        }
    }
}
