//
//  TerminalLinkDetector.swift
//  Kommando
//
//  Finds the URL or filesystem path under a given column of a terminal line so the
//  pane can offer ⌘-click activation with hover feedback (à la iTerm / VS Code).
//  Paths are confirmed against the shell's cwd so only real files/dirs light up.
//

import Foundation

enum TerminalLinkTarget: Equatable {
    case url(URL)
    case file(URL)
}

struct TerminalLink: Equatable {
    /// Inclusive start column and exclusive end column within the visible line.
    let startColumn: Int
    let endColumn: Int
    let target: TerminalLinkTarget
}

enum TerminalLinkDetector {
    /// Token-bounding characters. Whitespace plus quotes/brackets so wrapping
    /// punctuation isn't dragged into the match. NUL/control characters (SwiftTerm pads
    /// empty cells with NUL) are also treated as boundaries via `isBoundary`.
    private static let boundaries = Set<Character>(" \t\u{00a0}\"'`()[]{}<>")

    private static func isBoundary(_ char: Character) -> Bool {
        if boundaries.contains(char) {
            return true
        }
        return char.unicodeScalars.contains { $0.value < 0x20 || $0 == "\u{7f}" }
    }
    /// Trailing punctuation trimmed from the end of a token (e.g. "see https://x.com.").
    private static let trailingPunctuation = Set<Character>(".,;:!?")
    private static let urlSchemes = ["https://", "http://", "file://", "ftp://"]

    /// Returns the link occupying `column` on `line`, or nil if none. `cwd` is the
    /// shell's working directory, used to resolve relative paths.
    static func link(in line: String, atColumn column: Int, cwd: String?) -> TerminalLink? {
        let chars = Array(line)
        guard column >= 0, column < chars.count else { return nil }
        guard !isBoundary(chars[column]) else { return nil }

        var start = column
        while start > 0 && !isBoundary(chars[start - 1]) {
            start -= 1
        }
        var end = column
        while end < chars.count && !isBoundary(chars[end]) {
            end += 1
        }

        // Trim trailing punctuation, but never past the hovered column.
        while end - 1 > column, let last = chars[safe: end - 1], trailingPunctuation.contains(last) {
            end -= 1
        }
        guard end > start else { return nil }

        let token = String(chars[start..<end])

        if let url = urlTarget(from: token) {
            return TerminalLink(startColumn: start, endColumn: end, target: .url(url))
        }
        if let file = fileTarget(from: token, cwd: cwd) {
            return TerminalLink(startColumn: start, endColumn: end, target: .file(file))
        }
        return nil
    }

    private static func urlTarget(from token: String) -> URL? {
        let lower = token.lowercased()
        if urlSchemes.contains(where: { lower.hasPrefix($0) }) {
            return URL(string: token)
        }
        if lower.hasPrefix("www.") {
            return URL(string: "https://\(token)")
        }
        return nil
    }

    private static func fileTarget(from token: String, cwd: String?) -> URL? {
        guard !token.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\u{7f}" }) else {
            return nil
        }
        for candidate in pathCandidates(from: token) {
            let expanded = (candidate as NSString).expandingTildeInPath
            let resolved: String
            if expanded.hasPrefix("/") {
                resolved = expanded
            } else if let cwd, !cwd.isEmpty {
                resolved = (cwd as NSString).appendingPathComponent(expanded)
            } else {
                continue
            }
            if FileManager.default.fileExists(atPath: resolved) {
                return URL(fileURLWithPath: resolved)
            }
        }
        return nil
    }

    /// The token itself plus a variant with a trailing `:line[:col]` suffix removed,
    /// so compiler/grep style locations (`src/main.swift:42:5`) resolve to the file.
    private static func pathCandidates(from token: String) -> [String] {
        var candidates = [token]
        if let withoutLocation = stripLineColumnSuffix(token) {
            candidates.append(withoutLocation)
        }
        return candidates
    }

    private static func stripLineColumnSuffix(_ token: String) -> String? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var trailingNumbers = 0
        for part in parts.reversed() {
            if !part.isEmpty, part.allSatisfy(\.isNumber) {
                trailingNumbers += 1
            } else {
                break
            }
        }
        guard trailingNumbers > 0, trailingNumbers < parts.count else { return nil }
        return parts.dropLast(trailingNumbers).joined(separator: ":")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
