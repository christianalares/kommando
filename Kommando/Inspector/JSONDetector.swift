//
//  JSONDetector.swift
//  Kommando
//
//  Scans the terminal's currently-visible lines for JSON values that begin on their
//  own line (after optional whitespace), mirroring the Glaze inline JSON detector.
//

import Foundation

struct JSONMatch: Identifiable {
    let id = UUID()
    let row: Int
    let preview: String
    let value: JSONValue
}

enum JSONDetector {
    private static let maxBlockLines = 200

    static func detect(visibleLines lines: [String]) -> [JSONMatch] {
        var matches: [JSONMatch] = []
        var row = 0

        while row < lines.count {
            let trimmed = lines[row].trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "{" || first == "[" else {
                row += 1
                continue
            }

            var accumulated = ""
            var matchedEnd: Int?
            var matchedValue: JSONValue?

            let upper = min(lines.count, row + maxBlockLines)
            for end in row..<upper {
                accumulated += lines[end]
                accumulated += "\n"
                if let data = accumulated.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data),
                   object is [Any] || object is [String: Any] {
                    matchedEnd = end
                    matchedValue = JSONValue(object)
                    break
                }
            }

            if let matchedEnd, let matchedValue {
                matches.append(JSONMatch(row: row, preview: trimmed, value: matchedValue))
                row = matchedEnd + 1
            } else {
                row += 1
            }
        }

        return matches
    }
}
