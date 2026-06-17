//
//  JSONValue.swift
//  Kommando
//
//  An order-preserving (keys sorted for stability) JSON value plus a precomputed
//  node tree for the inspector UI. Shared by the terminal JSON inspector and the REPL.
//

import Foundation

indirect enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    init(_ any: Any) {
        switch any {
        case let dict as [String: Any]:
            self = .object(dict.keys.sorted().map { (key: $0, value: JSONValue(dict[$0]!)) })
        case let array as [Any]:
            self = .array(array.map { JSONValue($0) })
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.stringValue)
            }
        case let string as String:
            self = .string(string)
        case is NSNull:
            self = .null
        default:
            self = .string(String(describing: any))
        }
    }
}

struct InspectorNode: Identifiable {
    enum Kind {
        case object, array, string, number, bool, null
    }

    let id = UUID()
    let label: String
    let summary: String
    let kind: Kind
    let children: [InspectorNode]?

    init(label: String, value: JSONValue) {
        self.label = label
        switch value {
        case .object(let pairs):
            kind = .object
            summary = "{ \(pairs.count) }"
            children = pairs.map { InspectorNode(label: $0.key, value: $0.value) }
        case .array(let items):
            kind = .array
            summary = "[ \(items.count) ]"
            children = items.enumerated().map { InspectorNode(label: "\($0.offset)", value: $0.element) }
        case .string(let value):
            kind = .string
            summary = "\"\(value)\""
            children = nil
        case .number(let value):
            kind = .number
            summary = value
            children = nil
        case .bool(let value):
            kind = .bool
            summary = value ? "true" : "false"
            children = nil
        case .null:
            kind = .null
            summary = "null"
            children = nil
        }
    }
}
