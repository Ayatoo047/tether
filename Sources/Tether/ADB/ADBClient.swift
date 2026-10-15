import Foundation

/// Host and device services spoken directly to the adb server over its socket.
enum ADBClient {
    static func hostQuery(_ service: String) throws -> String {
        let socket = try ADBSocket()
        defer { socket.close() }
        try socket.sendRequest(service)
        try socket.readStatus()
        return try socket.readLengthPrefixed()
    }

    /// Opens a connection routed to one device's service (e.g. `sync:` or `shell:ls`).
    static func open(_ service: String, serial: String) throws -> ADBSocket {
        let socket = try ADBSocket()
        do {
            try socket.sendRequest("host:transport:\(serial)")
            try socket.readStatus()
            try socket.sendRequest(service)
            try socket.readStatus()
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    static func shell(serial: String, _ command: String) throws -> String {
        let socket = try open("shell:\(command)", serial: serial)
        defer { socket.close() }
        return String(decoding: try socket.readToEnd(), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Runs a shell command and throws with its output if it exits non-zero.
    @discardableResult
    static func run(serial: String, _ command: String) throws -> String {
        let marker = "__TETHER_RC="
        let output = try shell(serial: serial, "\(command) 2>&1; echo \"\(marker)$?\"")
        guard let range = output.range(of: marker, options: .backwards) else {
            throw TetherError.protocolError("missing exit status")
        }
        let code = Int(output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        let body = output[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0 else {
            throw TetherError.remote(body.isEmpty ? "The command failed on the device (exit code \(code))." : body)
        }
        return body
    }

    static func devices() throws -> [Device] {
        parseDevices(try hostQuery("host:devices-l"))
    }

    static func parseDevices(_ text: String) -> [Device] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { return nil }
            var info: [String: String] = [:]
            for part in parts.dropFirst(2) {
                if let colon = part.firstIndex(of: ":") {
                    info[String(part[..<colon])] = String(part[part.index(after: colon)...])
                }
            }
            let state = parts[1] == "no" ? "no permissions" : parts[1]
            return Device(
                kind: .adb,
                serial: parts[0],
                state: state,
                model: info["model"]?.replacingOccurrences(of: "_", with: " ")
            )
        }
    }

    private static let featureCache = FeatureCache()

    static func features(serial: String) -> Set<String> {
        if let cached = featureCache.get(serial) { return cached }
        guard let text = try? hostQuery("host-serial:\(serial):features") else { return [] }
        let features = Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        featureCache.set(serial, features)
        return features
    }
}

private final class FeatureCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Set<String>] = [:]

    func get(_ key: String) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: String, _ value: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
}

enum ADBServer {
    static func isRunning() -> Bool {
        (try? ADBClient.hostQuery("host:version")) != nil
    }

    static func ensureRunning() async throws {
        if await Task.detached(operation: { isRunning() }).value { return }
        let result = try await ADBTool.run(["start-server"], timeout: 30)
        guard await Task.detached(operation: { isRunning() }).value else {
            throw TetherError.serverUnavailable(result.output)
        }
    }
}
