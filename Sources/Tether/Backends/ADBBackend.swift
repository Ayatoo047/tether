import Foundation

/// Files over ADB (USB debugging / Wireless debugging; needs Developer options).
final class ADBBackend: FileBackend, @unchecked Sendable {
    let serial: String

    init(serial: String) {
        self.serial = serial
    }

    var cacheKey: String { "adb:\(serial)" }
    var rootPath: String { "/sdcard" }

    func list(_ path: String) throws -> [RemoteFile] {
        try SyncSession.listDirectory(serial: serial, path: path)
    }

    func walk(_ root: String) throws -> [(relative: String, file: RemoteFile)] {
        let session = try SyncSession(serial: serial)
        defer { session.close() }
        return try session.walk(root)
    }

    func download(_ file: RemoteFile, to url: URL, progress: TransferProgress) throws {
        let session = try SyncSession(serial: serial, progress: progress)
        defer { session.close() }
        try session.pull(file.path, to: url, progress: progress)
    }

    func upload(_ local: URL, to remotePath: String, modified: Date, progress: TransferProgress) throws {
        let session = try SyncSession(serial: serial, progress: progress)
        defer { session.close() }
        try session.push(local, to: remotePath, modified: modified, progress: progress)

        // Ask older Android versions to index the file so it shows up in Gallery etc.
        let serial = serial
        if let encoded = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            DispatchQueue.global(qos: .utility).async {
                _ = try? ADBClient.shell(serial: serial,
                    "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(RemotePath.quote("file://" + encoded)) >/dev/null 2>&1")
            }
        }
    }

    func exists(_ path: String) throws -> Bool {
        let session = try SyncSession(serial: serial)
        defer { session.close() }
        return try session.stat(path).exists
    }

    func makeDirectories(_ paths: [String]) throws {
        for start in stride(from: 0, to: paths.count, by: 50) {
            let batch = paths[start..<min(start + 50, paths.count)]
            try ADBClient.run(serial: serial, "mkdir -p " + batch.map(RemotePath.quote).joined(separator: " "))
        }
    }

    func rename(_ file: RemoteFile, to newName: String) throws {
        let destination = RemotePath.join(RemotePath.parent(file.path), newName)
        let displayName = newName.replacingOccurrences(of: "'", with: "")
        try ADBClient.run(serial: serial,
            "if [ -e \(RemotePath.quote(destination)) ]; then echo 'An item named “\(displayName)” already exists.'; exit 1; fi; mv \(RemotePath.quote(file.path)) \(RemotePath.quote(destination))")
    }

    func delete(_ files: [RemoteFile]) throws {
        try ADBClient.run(serial: serial, "rm -rf " + files.map { RemotePath.quote($0.path) }.joined(separator: " "))
    }

    func freeSpace(at path: String) -> Int64? {
        guard let output = try? ADBClient.shell(serial: serial, "df -k \(RemotePath.quote(path)) 2>/dev/null"),
              let line = output.split(separator: "\n").last else { return nil }
        let columns = line.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 4, let available = Int64(columns[3]) else { return nil }
        return available * 1024
    }

    func breadcrumbs(for path: String) -> [(title: String, path: String)] {
        for root in ["/sdcard", "/storage/emulated/0"] where path == root || path.hasPrefix(root + "/") {
            return crumbs(path, from: root, title: "Internal Storage")
        }
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "storage" {
            return crumbs(path, from: "/storage/\(parts[1])", title: "SD Card")
        }
        return crumbs(path, from: "/", title: "Phone")
    }

    private func crumbs(_ path: String, from root: String, title: String) -> [(title: String, path: String)] {
        var result = [(title: title, path: root)]
        var current = root == "/" ? "" : root
        for component in path.dropFirst(root.count).split(separator: "/") {
            current += "/" + component
            result.append((String(component), current))
        }
        return result
    }

    func loadLocations() throws -> [StorageLocation] {
        // SD cards and USB drives are mounted under /storage.
        let volumes = ((try? list("/storage")) ?? [])
            .filter { $0.isDirectory && !["emulated", "self"].contains($0.name) }
            .map { StorageLocation(name: "SD Card (\($0.name))", path: $0.path, systemImage: "sdcard") }
        return StorageLocation.standard(root: "/sdcard", rootName: "Internal Storage") + volumes
    }
}
