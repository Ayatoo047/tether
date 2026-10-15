import Darwin
import Foundation

enum TetherError: LocalizedError {
    case adbNotFound
    case serverUnavailable(String)
    case connectionFailed(String)
    case protocolError(String)
    case remote(String)
    case connectionClosed
    case phoneLocked

    var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "The adb tool could not be found. Install it with `brew install --cask android-platform-tools` and relaunch."
        case .serverUnavailable(let message):
            return "Could not start the adb server. \(message)"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .protocolError(let message):
            return "Unexpected response from the device (\(message))."
        case .remote(let message):
            return message
        case .connectionClosed:
            return "The connection to the device was closed."
        case .phoneLocked:
            return "Unlock your phone to see its files. If it's already unlocked, pull down the notification shade, tap the USB notification and choose “File transfer”."
        }
    }
}

/// A blocking TCP connection to the local adb server (127.0.0.1:5037).
/// All calls block, so use it from background threads only.
final class ADBSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(port: UInt16 = 5037) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TetherError.connectionFailed(String(cString: strerror(errno))) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw TetherError.connectionFailed(message)
        }
        self.fd = fd
    }

    deinit { close() }

    private func currentFD() throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { throw TetherError.connectionClosed }
        return fd
    }

    /// Unblocks any pending read/write from another thread (used for cancellation).
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    // MARK: Raw I/O

    func send(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let fd = try currentFD()
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw TetherError.connectionFailed(String(cString: strerror(errno)))
                }
                if n == 0 { throw TetherError.connectionClosed }
                offset += n
            }
        }
    }

    func read(exactly count: Int) throws -> Data {
        var data = Data(count: count)
        guard count > 0 else { return data }
        let fd = try currentFD()
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < count {
                let n = Darwin.recv(fd, buffer.baseAddress! + offset, count - offset, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw TetherError.connectionFailed(String(cString: strerror(errno)))
                }
                if n == 0 { throw TetherError.connectionClosed }
                offset += n
            }
        }
        return data
    }

    func readToEnd() throws -> Data {
        let fd = try currentFD()
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n < 0 {
                if errno == EINTR { continue }
                throw TetherError.connectionFailed(String(cString: strerror(errno)))
            }
            if n == 0 { break }
            result.append(buffer, count: n)
        }
        return result
    }

    func readString(_ count: Int) throws -> String {
        String(decoding: try read(exactly: count), as: UTF8.self)
    }

    // MARK: Smart-socket protocol

    /// Sends a host request framed as a 4-digit hex length followed by the payload.
    func sendRequest(_ service: String) throws {
        let body = Data(service.utf8)
        var message = Data(String(format: "%04x", body.count).utf8)
        message.append(body)
        try send(message)
    }

    func readStatus() throws {
        let status = try readString(4)
        switch status {
        case "OKAY": return
        case "FAIL": throw TetherError.remote(try readLengthPrefixed())
        default: throw TetherError.protocolError(status)
        }
    }

    func readLengthPrefixed() throws -> String {
        let header = try readString(4)
        guard let length = Int(header, radix: 16) else { throw TetherError.protocolError(header) }
        return try readString(length)
    }
}

extension Data {
    func le32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(self[startIndex + offset + i]) << (8 * i) }
        return value
    }

    func le64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(self[startIndex + offset + i]) << (8 * i) }
        return value
    }

    func ascii(_ range: Range<Int>) -> String {
        String(decoding: self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)], as: UTF8.self)
    }

    mutating func appendLE32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
