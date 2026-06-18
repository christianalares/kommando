//
//  MCPControlServer.swift
//  Kommando
//
//  A tiny Unix-domain socket server speaking newline-delimited JSON. Each request names an
//  op (list/read/write/control/create/focus/close) and carries the shared token; requests
//  are dispatched onto the main actor where the live terminal state lives. The MCP protocol
//  itself is handled by the external `kommando-mcp` helper, which is this socket's only
//  intended client.
//

import Foundation
import Darwin

/// Response envelope written back for every request. Only the relevant fields are set.
private struct ControlResponse: Encodable {
    var ok: Bool
    var error: String?
    var id: String?
    var text: String?
    var sessions: [MCPSessionInfo]?
}

final class MCPControlServer {
    private let socketPath: String
    private let token: String

    private var listenFD: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.kommando.mcp.socket", qos: .userInitiated)

    init(socketPath: String, token: String) {
        self.socketPath = socketPath
        self.token = token
    }

    // MARK: - Lifecycle

    func start() throws {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = socketPath.utf8.count
        guard pathLen < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathLen + 1) { dst in
                _ = strcpy(dst, socketPath)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, size)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE)
        }
        // Only the current user may connect to the socket.
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            close(fd)
            unlink(socketPath)
            throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
        }

        listenFD = fd
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Accept / read loops

    private func acceptLoop() {
        while running {
            let connFD = accept(listenFD, nil, nil)
            if connFD < 0 {
                if running { continue } else { break }
            }
            var on: Int32 = 1
            setsockopt(connFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in
                self?.handleConnection(connFD)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while running {
            let n = read(fd, &chunk, chunkSize)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                let response = dispatch(line)
                writeAll(fd, response)
            }
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                let written = write(fd, ptr, remaining)
                if written <= 0 { break }
                ptr = ptr.advanced(by: written)
                remaining -= written
            }
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ data: Data) -> Data {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.handle(data)
            }
        }
    }

    @MainActor
    private func handle(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(ControlResponse(ok: false, error: "Invalid JSON request"))
        }
        guard (object["token"] as? String) == token else {
            return encode(ControlResponse(ok: false, error: "Unauthorized"))
        }

        let op = object["op"] as? String ?? ""
        let id = object["id"] as? String

        do {
            switch op {
            case "list":
                return encode(ControlResponse(ok: true, sessions: TerminalControl.listSessions()))

            case "read":
                let lines = intValue(object["lines"]) ?? 50
                let text = try TerminalControl.read(id: id, lines: lines)
                return encode(ControlResponse(ok: true, id: id, text: text))

            case "write":
                guard let text = object["text"] as? String else {
                    throw TerminalControlError.badInput("Missing 'text'.")
                }
                let execute = object["execute"] as? Bool ?? false
                let resolvedId = try TerminalControl.write(id: id, text: text, execute: execute)
                return encode(ControlResponse(ok: true, id: resolvedId))

            case "control":
                guard let letter = object["letter"] as? String else {
                    throw TerminalControlError.badInput("Missing 'letter'.")
                }
                let resolvedId = try TerminalControl.sendControl(id: id, letter: letter)
                return encode(ControlResponse(ok: true, id: resolvedId))

            case "create":
                let inspector = object["inspector"] as? Bool ?? false
                let newId = try TerminalControl.createTerminal(inspector: inspector)
                return encode(ControlResponse(ok: true, id: newId))

            case "split":
                let inspector = object["inspector"] as? Bool ?? false
                let direction = object["direction"] as? String ?? "vertical"
                let newId = try TerminalControl.split(id: id, direction: direction, inspector: inspector)
                return encode(ControlResponse(ok: true, id: newId))

            case "focus":
                guard let id else { throw TerminalControlError.badInput("Missing 'id'.") }
                return encode(ControlResponse(ok: true, id: try TerminalControl.focus(id: id)))

            case "close":
                guard let id else { throw TerminalControlError.badInput("Missing 'id'.") }
                return encode(ControlResponse(ok: true, id: try TerminalControl.close(id: id)))

            default:
                return encode(ControlResponse(ok: false, error: "Unknown op: \(op)"))
            }
        } catch {
            return encode(ControlResponse(ok: false, error: String(describing: error)))
        }
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func encode(_ response: ControlResponse) -> Data {
        var data = (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false,"error":"encode failed"}"#.utf8)
        data.append(0x0A)
        return data
    }
}
