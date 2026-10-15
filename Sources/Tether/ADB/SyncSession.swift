import Foundation

struct RemoteStat {
    let mode: UInt32
    let size: Int64
    let mtime: Int64
    let exists: Bool
    var isDirectory: Bool { mode & 0o170000 == 0o040000 }
}

/// adb's file sync protocol (the same one `adb push`/`adb pull` use).
/// One session handles one request at a time; open separate sessions for parallel work.
final class SyncSession {
    static let maxChunk = 64 * 1024

    let socket: ADBSocket
    private let statV2: Bool
    private let listV2: Bool

    init(serial: String, progress: TransferProgress? = nil) throws {
        let features = ADBClient.features(serial: serial)
        statV2 = features.contains("stat_v2")
        listV2 = features.contains("ls_v2")
        socket = try ADBClient.open("sync:", serial: serial)
        progress?.attach(socket)
    }

    func close() {
        try? send("QUIT", Data())
        socket.close()
    }

    static func listDirectory(serial: String, path: String) throws -> [RemoteFile] {
        let session = try SyncSession(serial: serial)
        defer { session.close() }
        return try session.list(path)
    }

    // MARK: Framing

    private func send(_ id: String, _ payload: Data) throws {
        var message = Data(id.utf8)
        message.appendLE32(UInt32(payload.count))
        message.append(payload)
        try socket.send(message)
    }

    private func send(_ id: String, path: String) throws {
        try send(id, Data(path.utf8))
    }

    // MARK: Listing

    func list(_ directory: String) throws -> [RemoteFile] {
        var items: [RemoteFile] = []
        if listV2 {
            try send("LIS2", path: directory)
            while true {
                // id, error, dev, ino, mode, nlink, uid, gid, size, atime, mtime, ctime, namelen
                let header = try socket.read(exactly: 76)
                let id = header.ascii(0..<4)
                if id == "DONE" { break }
                guard id == "DNT2" else { throw TetherError.protocolError(id) }
                let name = try socket.readString(Int(header.le32(at: 72)))
                guard header.le32(at: 4) == 0, name != ".", name != ".." else { continue }
                items.append(RemoteFile(
                    directory: directory, name: name, mode: header.le32(at: 24),
                    size: Int64(bitPattern: header.le64(at: 40)),
                    mtime: Int64(bitPattern: header.le64(at: 56))))
            }
        } else {
            try send("LIST", path: directory)
            while true {
                // id, mode, size, mtime, namelen
                let header = try socket.read(exactly: 20)
                let id = header.ascii(0..<4)
                if id == "DONE" { break }
                guard id == "DENT" else { throw TetherError.protocolError(id) }
                let name = try socket.readString(Int(header.le32(at: 16)))
                guard name != ".", name != ".." else { continue }
                items.append(RemoteFile(
                    directory: directory, name: name, mode: header.le32(at: 4),
                    size: Int64(header.le32(at: 8)), mtime: Int64(header.le32(at: 12))))
            }
        }

        // Resolve symlinks (e.g. /sdcard) so folders behave like folders.
        for index in items.indices where items[index].isSymlink {
            if statV2 {
                if let target = try? stat(items[index].path, followLinks: true), target.exists {
                    items[index].isDirectory = target.isDirectory
                    if !target.isDirectory { items[index].size = target.size }
                }
            } else {
                items[index].isDirectory = true
            }
        }
        return items
    }

    /// Recursively lists a directory; parents always come before their children.
    func walk(_ root: String) throws -> [(relative: String, file: RemoteFile)] {
        var result: [(relative: String, file: RemoteFile)] = []
        var stack: [(path: String, relative: String)] = [(root, "")]
        while let (directory, relative) = stack.popLast() {
            for file in try list(directory) {
                let childRelative = relative.isEmpty ? file.name : relative + "/" + file.name
                result.append((childRelative, file))
                if file.isDirectory && !file.isSymlink {
                    stack.append((file.path, childRelative))
                }
            }
        }
        return result
    }

    func stat(_ path: String, followLinks: Bool = false) throws -> RemoteStat {
        if statV2 {
            let command = followLinks ? "STA2" : "LST2"
            try send(command, path: path)
            let reply = try socket.read(exactly: 72)
            guard reply.ascii(0..<4) == command else { throw TetherError.protocolError(reply.ascii(0..<4)) }
            return RemoteStat(
                mode: reply.le32(at: 24),
                size: Int64(bitPattern: reply.le64(at: 40)),
                mtime: Int64(bitPattern: reply.le64(at: 56)),
                exists: reply.le32(at: 4) == 0)
        } else {
            try send("STAT", path: path)
            let reply = try socket.read(exactly: 16)
            guard reply.ascii(0..<4) == "STAT" else { throw TetherError.protocolError(reply.ascii(0..<4)) }
            let mode = reply.le32(at: 4)
            return RemoteStat(mode: mode, size: Int64(reply.le32(at: 8)), mtime: Int64(reply.le32(at: 12)), exists: mode != 0)
        }
    }

    /// Returns `name`, or "name (1).ext" etc. if something already exists at that path.
    func availableName(_ name: String, in directory: String) throws -> String {
        guard try stat(RemotePath.join(directory, name)).exists else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for index in 1... {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if try !stat(RemotePath.join(directory, candidate)).exists { return candidate }
        }
        return name
    }

    // MARK: Transfers

    func pull(_ remotePath: String, to localURL: URL, progress: TransferProgress?) throws {
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        try send("RECV", path: remotePath)
        while true {
            let header = try socket.read(exactly: 8)
            let id = header.ascii(0..<4)
            let length = Int(header.le32(at: 4))
            switch id {
            case "DATA":
                let chunk = try socket.read(exactly: length)
                try handle.write(contentsOf: chunk)
                progress?.add(length)
                try progress?.checkCancelled()
            case "DONE":
                return
            case "FAIL":
                throw TetherError.remote(try socket.readString(length))
            default:
                throw TetherError.protocolError(id)
            }
        }
    }

    func push(_ localURL: URL, to remotePath: String, mode: UInt32 = 0o100644, modified: Date, progress: TransferProgress?) throws {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        try send("SEND", path: "\(remotePath),\(mode)")
        do {
            while let chunk = try handle.read(upToCount: Self.maxChunk), !chunk.isEmpty {
                try progress?.checkCancelled()
                try send("DATA", chunk)
                progress?.add(chunk.count)
            }
            var done = Data("DONE".utf8)
            done.appendLE32(UInt32(clamping: Int(modified.timeIntervalSince1970)))
            try socket.send(done)
        } catch let error as TetherError {
            // The device may have rejected the file early; surface its reason if it sent one.
            if let header = try? socket.read(exactly: 8), header.ascii(0..<4) == "FAIL",
               let message = try? socket.readString(Int(header.le32(at: 4))) {
                throw TetherError.remote(message)
            }
            throw error
        }

        let header = try socket.read(exactly: 8)
        switch header.ascii(0..<4) {
        case "OKAY": return
        case "FAIL": throw TetherError.remote(try socket.readString(Int(header.le32(at: 4))))
        default: throw TetherError.protocolError(header.ascii(0..<4))
        }
    }
}
