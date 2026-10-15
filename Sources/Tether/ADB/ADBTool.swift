import Foundation

/// Runs the `adb` command-line tool for things that are simplest through it:
/// starting the server, Wi-Fi pairing (TLS + SPAKE2), connecting and mDNS discovery.
enum ADBTool {
    struct Output {
        let status: Int32
        let output: String
    }

    struct MDNSService: Hashable {
        let name: String
        let type: String
        let address: String
        var isPairing: Bool { type.contains("_adb-tls-pairing") }
        var isConnect: Bool { type.contains("_adb-tls-connect") }
    }

    static let executableURL: URL? = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        // Prefer an adb that's already installed so we never fight Android Studio's server version;
        // fall back to the copy bundled inside the app.
        var candidates = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "adb") {
            candidates.append(bundled.path)
        }
        return candidates.first(where: fm.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }()

    static func run(_ arguments: [String], timeout: TimeInterval = 20) async throws -> Output {
        guard let executable = executableURL else { throw TetherError.adbNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Output goes to a file, not a pipe: `adb` may fork the server daemon, which would
                // inherit a pipe and keep it open forever.
                let logURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tether-adb-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: logURL) }
                guard let log = try? FileHandle(forWritingTo: logURL) else {
                    continuation.resume(throwing: TetherError.remote("Could not create a temporary file."))
                    return
                }

                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["ADB_MDNS_OPENSCREEN"] = "1"
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = log
                process.standardError = log

                do {
                    try process.run()
                } catch {
                    try? log.close()
                    continuation.resume(throwing: error)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                try? log.close()

                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    output: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    static func mdnsServices() async -> [MDNSService] {
        guard let result = try? await run(["mdns", "services"], timeout: 10) else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 3, parts[1].contains("_adb") else { return nil }
            return MDNSService(name: parts[0], type: parts[1], address: parts[parts.count - 1])
        }
    }

    /// Returns the device GUID on success.
    static func pair(address: String, code: String) async throws -> String? {
        let result = try await run(["pair", address, code], timeout: 30)
        guard result.output.contains("Successfully paired") else {
            throw TetherError.remote(cleaned(result.output, fallback: "Pairing failed. Check the code and try again."))
        }
        return firstCapture(#"guid=([^\]\s]+)"#, in: result.output)
    }

    static func connect(_ address: String) async throws {
        let result = try await run(["connect", address], timeout: 20)
        let text = result.output.lowercased()
        guard text.contains("connected to"), !text.contains("failed"), !text.contains("cannot"), !text.contains("unable") else {
            throw TetherError.remote(cleaned(result.output, fallback: "Could not connect to \(address)."))
        }
    }

    static func disconnect(_ serial: String) async throws {
        _ = try await run(["disconnect", serial])
    }

    static func tcpip(serial: String, port: Int = 5555) async throws {
        let result = try await run(["-s", serial, "tcpip", String(port)])
        guard result.status == 0 else {
            throw TetherError.remote(cleaned(result.output, fallback: "Could not switch the device to Wi-Fi mode."))
        }
    }

    private static func cleaned(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasPrefix("Failed: ") ? String(trimmed.dropFirst(8)) : trimmed
    }
}
