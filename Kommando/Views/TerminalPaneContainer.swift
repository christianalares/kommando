//
//  TerminalPaneContainer.swift
//  Kommando
//
//  Hosts a terminal pane and overlays: a ⌘F find bar (top-right) and clickable {}
//  badges on lines where JSON output was detected. Clicking a badge opens the value
//  inspector — the native take on the Glaze inline JSON inspector.
//

import SwiftUI
import SwiftTerm

struct TerminalPaneContainer: View {
    let session: TerminalSession
    var isFocused: Bool = false

    @State private var selectedMatch: JSONMatch?

    var body: some View {
        GeometryReader { geo in
            let rows = max(1, session.terminalView.getTerminal().rows)
            let cellHeight = geo.size.height / CGFloat(rows)

            ZStack(alignment: .topTrailing) {
                TerminalPaneView(session: session, isFocused: isFocused)

                jsonBadges(geo: geo, cellHeight: cellHeight)

                if session.findVisible {
                    PaneFindBar(session: session)
                        .padding(.top, 8)
                        .padding(.trailing, 10)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.12), value: session.findVisible)
        }
    }

    @ViewBuilder
    private func jsonBadges(geo: GeometryProxy, cellHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.jsonMatches) { match in
                Button {
                    selectedMatch = match
                } label: {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Inspect JSON")
                .position(
                    x: geo.size.width - 18,
                    y: CGFloat(match.row) * cellHeight + cellHeight / 2
                )
                .popover(isPresented: bindingForPopover(match)) {
                    ValueInspectorView(root: match.value)
                        .frame(width: 440, height: 380)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bindingForPopover(_ match: JSONMatch) -> Binding<Bool> {
        Binding(
            get: { selectedMatch?.id == match.id },
            set: { isShown in
                if !isShown, selectedMatch?.id == match.id {
                    selectedMatch = nil
                }
            }
        )
    }
}
