import Darwin
import Foundation
import Network
import UniformTypeIdentifiers

/// "Browser Link": a tiny web server on this Mac. The phone opens it in its normal browser
/// (no app, no Developer mode) to send files to the Mac and download files shared from the Mac.
@MainActor
final class WebLinkServer: ObservableObject {
    static let shared = WebLinkServer()

    struct SharedFile: Identifiable, Hashable {
        let id: String
        let url: URL
        let name: String
        let size: Int64
    }

    struct ReceivedFile: Identifiable {
        enum State { case receiving, done, failed }
        let id: UUID
        var name: String
        var url: URL
        var total: Int64
        var received: Int64
        var state: State
    }

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16?
    @Published private(set) var address: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var shared: [SharedFile] = []
    @Published private(set) var received: [ReceivedFile] = []
    @Published private(set) var lastPhoneActivity: Date?

    private var listener: NWListener?
    private let core: WebLinkCore
    private let pathMonitor = NWPathMonitor()

    private init() {
        let defaults = UserDefaults.standard
        let token = defaults.string(forKey: "webLinkToken") ?? {
            let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            let token = String((0..<20).map { _ in alphabet.randomElement()! })
            defaults.set(token, forKey: "webLinkToken")
            return token
        }()
        core = WebLinkCore(token: token)
        core.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Keep the link/QR code current when the Mac changes networks (e.g. joins the phone's hotspot).
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.refreshAddress()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "tether.weblink.path"))
    }

    var url: URL? {
        guard let address, let port else { return nil }
        return URL(string: "http://\(address):\(port)/?k=\(core.token)")
    }

    /// Starts on port 8765 (so a saved link keeps working), or any free port if that's taken.
    func start(preferFixedPort: Bool = true) {
        guard listener == nil else { return }
        UserDefaults.standard.set(true, forKey: "webLinkEnabled")
        address = Self.localIPv4()
        errorMessage = nil
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = preferFixedPort
                ? try NWListener(using: parameters, on: 8765)
                : try NWListener(using: parameters)
            let core = core
            listener.newConnectionHandler = { connection in core.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue
                        self.isRunning = true
                    case .failed(let error):
                        self.stop()
                        if preferFixedPort {
                            self.start(preferFixedPort: false)
                        } else {
                            self.errorMessage = "Couldn't start the link: \(error.localizedDescription)"
                        }
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: core.queue)
        } catch {
            if preferFixedPort {
                start(preferFixedPort: false)
            } else {
                errorMessage = "Couldn't start the link: \(error.localizedDescription)"
            }
        }
    }

    /// Turns the link back on at launch if it was on last time, so a saved link keeps working.
    func restoreIfEnabled() {
        if UserDefaults.standard.bool(forKey: "webLinkEnabled") { start() }
    }

    /// Stops the link and keeps it off at next launch.
    func turnOff() {
        UserDefaults.standard.set(false, forKey: "webLinkEnabled")
        stop()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = nil
    }

    func refreshAddress() {
        let current = Self.localIPv4()
        if current != address { address = current }
    }

    func share(_ urls: [URL]) {
        for url in urls where !shared.contains(where: { $0.url == url }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            shared.append(SharedFile(id: UUID().uuidString.lowercased(), url: url, name: url.lastPathComponent.precomposedStringWithCanonicalMapping, size: size))
        }
        core.setShared(shared)
    }

    func unshare(_ file: SharedFile) {
        shared.removeAll { $0.id == file.id }
        core.setShared(shared)
    }

    func clearReceived() {
        received.removeAll { $0.state != .receiving }
    }

    private func handle(_ event: WebLinkCore.Event) {
        lastPhoneActivity = Date()
        switch event {
        case .activity:
            break
        case .receiveStarted(let id, let name, let url, let total):
            received.insert(ReceivedFile(id: id, name: name, url: url, total: total, received: 0, state: .receiving), at: 0)
        case .receiveProgress(let id, let bytes):
            if let index = received.firstIndex(where: { $0.id == id }) { received[index].received = bytes }
        case .receiveFinished(let id, let url, let success):
            if let index = received.firstIndex(where: { $0.id == id }) {
                received[index].state = success ? .done : .failed
                received[index].url = url
                received[index].name = url.lastPathComponent
                if success { received[index].received = received[index].total }
            }
        }
    }

    /// Picks this Mac's Wi-Fi/Ethernet IPv4 address.
    static func localIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(interface: String, ip: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            candidates.append((String(cString: pointer.pointee.ifa_name), ip))
        }
        func isPrivate(_ ip: String) -> Bool {
            if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") { return true }
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            return parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1])
        }
        return candidates.first { $0.interface.hasPrefix("en") && isPrivate($0.ip) }?.ip
            ?? candidates.first { isPrivate($0.ip) }?.ip
            ?? candidates.first?.ip
    }
}

/// Connection handling, entirely on `queue`. Minimal HTTP/1.1: one request per connection.
final class WebLinkCore: @unchecked Sendable {
    enum Event {
        case activity
        case receiveStarted(id: UUID, name: String, url: URL, total: Int64)
        case receiveProgress(id: UUID, bytes: Int64)
        case receiveFinished(id: UUID, url: URL, success: Bool)
    }

    let queue = DispatchQueue(label: "tether.weblink")
    let token: String
    var onEvent: ((Event) -> Void)?

    private let lock = NSLock()
    private var sharedFiles: [WebLinkServer.SharedFile] = []

    init(token: String) {
        self.token = token
    }

    func setShared(_ files: [WebLinkServer.SharedFile]) {
        lock.lock(); sharedFiles = files; lock.unlock()
    }

    private func sharedFile(_ id: String) -> WebLinkServer.SharedFile? {
        lock.lock(); defer { lock.unlock() }
        return sharedFiles.first { $0.id == id }
    }

    func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    // MARK: Request parsing

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.first == 0x16 {
                // TLS ClientHello: this server is HTTP-only. Closing right away makes the browser retry over http://.
                connection.cancel()
                return
            }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                route(connection, head: head, body: Data(buffer[end.upperBound...]))
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                readHead(connection, buffer: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, head: String, body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return respond(connection, status: "400 Bad Request", text: "Bad request") }
        let method = String(requestLine[0])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let components = URLComponents(string: "http://phone" + requestLine[1])
        let path = components?.path ?? "/"
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        guard query["k"] == token else {
            if path == "/" {
                return respond(connection, status: "403 Forbidden", type: "text/html; charset=utf-8",
                               body: Data(WebLinkPage.locked.utf8))
            }
            return respond(connection, status: "403 Forbidden", text: "Forbidden")
        }
        onEvent?(.activity)

        switch (method, path) {
        case ("GET", "/"):
            respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(WebLinkPage.html.utf8))
        case ("GET", "/api/state"):
            sendState(connection)
        case ("GET", _) where path.hasPrefix("/dl/"):
            let id = String(path.dropFirst(4).prefix { $0 != "/" })
            guard let file = sharedFile(id) else { return respond(connection, status: "404 Not Found", text: "That file is no longer shared.") }
            sendFile(connection, file: file, inline: query["inline"] == "1")
        case ("PUT", "/up"), ("POST", "/up"):
            guard let length = Int64(headers["content-length"] ?? "") else {
                return respond(connection, status: "411 Length Required", text: "Missing length")
            }
            receive(connection, name: query["name"] ?? "file", length: length, initial: body)
        default:
            respond(connection, status: "404 Not Found", text: "Not found")
        }
    }

    // MARK: Responses

    private func respond(_ connection: NWConnection, status: String, text: String) {
        respond(connection, status: status, type: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendState(_ connection: NWConnection) {
        lock.lock()
        let files = sharedFiles
        lock.unlock()
        let payload: [String: Any] = [
            "mac": Host.current().localizedName ?? "Mac",
            "files": files.map { file -> [String: Any] in
                let type = UTType(filenameExtension: file.url.pathExtension)
                return [
                    "id": file.id, "name": file.name, "size": file.size,
                    "kind": type?.conforms(to: .image) == true ? "image"
                        : type?.conforms(to: .movie) == true ? "video"
                        : type?.conforms(to: .audio) == true ? "audio" : "file",
                ]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        respond(connection, status: "200 OK", type: "application/json", body: data)
    }

    private func sendFile(_ connection: NWConnection, file: WebLinkServer.SharedFile, inline: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            return respond(connection, status: "404 Not Found", text: "The file can't be read on the Mac.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value ?? file.size
        let mime = UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let encodedName = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ";,"))) ?? "file"
        let asciiName = file.name.unicodeScalars.map { $0.isASCII && $0 != "\"" ? String($0) : "_" }.joined()
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(size)\r\n"
            + "Content-Disposition: \(inline ? "inline" : "attachment"); filename=\"\(asciiName)\"; filename*=UTF-8''\(encodedName)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            pump(connection, handle)
        })
    }

    private func pump(_ connection: NWConnection, _ handle: FileHandle) {
        let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            pump(connection, handle)
        })
    }

    // MARK: Uploads from the phone

    private func receive(_ connection: NWConnection, name rawName: String, length: Int64, initial: Data) {
        var name = (rawName as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "file" }

        let folder = AppSettings.downloadFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = TransferJobs.uniqueLocalURL(folder.appendingPathComponent(name))
        let partial = folder.appendingPathComponent(".tether-\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partial) else {
            return respond(connection, status: "500 Internal Server Error", text: "The Mac couldn't save the file.")
        }

        let id = UUID()
        onEvent?(.receiveStarted(id: id, name: destination.lastPathComponent, url: destination, total: length))
        let first = initial.prefix(Int(clamping: length))
        try? handle.write(contentsOf: first)
        let state = UploadState(id: id, handle: handle, partial: partial, destination: destination,
                                remaining: length - Int64(first.count), received: Int64(first.count))
        receiveLoop(connection, state)
    }

    private final class UploadState {
        let id: UUID
        let handle: FileHandle
        let partial: URL
        let destination: URL
        var remaining: Int64
        var received: Int64
        var lastReport = Date.distantPast

        init(id: UUID, handle: FileHandle, partial: URL, destination: URL, remaining: Int64, received: Int64) {
            self.id = id; self.handle = handle; self.partial = partial
            self.destination = destination; self.remaining = remaining; self.received = received
        }
    }

    private func receiveLoop(_ connection: NWConnection, _ state: UploadState) {
        if state.remaining <= 0 {
            try? state.handle.close()
            let saved = (try? FileManager.default.moveItem(at: state.partial, to: state.destination)) != nil
            onEvent?(.receiveFinished(id: state.id, url: state.destination, success: saved))
            let json = "{\"ok\":\(saved),\"name\":\(Self.jsonString(state.destination.lastPathComponent))}"
            return respond(connection, status: saved ? "200 OK" : "500 Internal Server Error", type: "application/json", body: Data(json.utf8))
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Int(min(state.remaining, 1 << 20))) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                do {
                    try state.handle.write(contentsOf: data)
                } catch {
                    return fail(connection, state)
                }
                state.remaining -= Int64(data.count)
                state.received += Int64(data.count)
                if Date().timeIntervalSince(state.lastReport) > 0.2 {
                    state.lastReport = Date()
                    onEvent?(.receiveProgress(id: state.id, bytes: state.received))
                }
            }
            if error != nil || (isComplete && state.remaining > 0) {
                return fail(connection, state)
            }
            receiveLoop(connection, state)
        }
    }

    private func fail(_ connection: NWConnection, _ state: UploadState) {
        try? state.handle.close()
        try? FileManager.default.removeItem(at: state.partial)
        onEvent?(.receiveFinished(id: state.id, url: state.destination, success: false))
        connection.cancel()
    }

    private static func jsonString(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }
}
