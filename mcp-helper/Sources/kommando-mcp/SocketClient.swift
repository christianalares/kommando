//
//  SocketClient.swift
//  kommando-mcp
//
//  Thin client for Kommando's local control socket. One short-lived connection per call:
//  open, send a newline-terminated JSON request, read one JSON response line, close.
//  Never writes to stdout/stderr — that stream belongs to the MCP protocol.
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SocketClient {
    /// Sends a request to the running Kommando app and returns its decoded JSON response.
    static func request(_ payload: [String: Any]) -> [String: Any] {
        var request = payload
        request["token"] = token()

        guard let body = try? JSONSerialization.data(withJSONObject: request) else {
            return ["ok": false, "error": "Failed to encode request."]
        }

        let path = socketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return ["ok": false, "error": "socket() failed."] }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            return ["ok": false, "error": "Socket path too long."]
        }
        path.withCString { cs in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: path.utf8.count + 1) { dst in
                    _ = strcpy(dst, cs)
                }
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, size)
            }
        }
        guard connected == 0 else {
            return ["ok": false, "error": "Kommando isn't running, or its MCP server is turned off (Settings → MCP)."]
        }

        var line = body
        line.append(0x0A)
        if !writeAll(fd, line) {
            return ["ok": false, "error": "Failed to send request to Kommando."]
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.contains(0x0A) { break }
        }

        guard let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
            return ["ok": false, "error": "Invalid response from Kommando."]
        }
        return object
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var remaining = data.count
            while remaining > 0 {
                let written = write(fd, ptr, remaining)
                if written <= 0 { return false }
                ptr = ptr.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    // MARK: - Paths (must match the app's MCPPaths)

    private static func supportDirectory() -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/Kommando"
    }

    private static func socketPath() -> String {
        ProcessInfo.processInfo.environment["KOMMANDO_MCP_SOCKET"]
            ?? (supportDirectory() + "/mcp.sock")
    }

    private static func token() -> String {
        if let env = ProcessInfo.processInfo.environment["KOMMANDO_MCP_TOKEN"], !env.isEmpty {
            return env
        }
        let tokenFile = supportDirectory() + "/mcp-token"
        return (try? String(contentsOfFile: tokenFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
