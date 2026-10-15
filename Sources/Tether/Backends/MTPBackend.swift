import CLibMTP
import Foundation

/// libmtp isn't thread-safe and MTP allows one operation at a time per phone,
/// so every libmtp call goes through this one lock.
enum MTP {
    static let lock = NSRecursiveLock()
    private static let initialized: Void = { LIBMTP_Init() }()
    static func initialize() { _ = initialized }
    static let rootObject: UInt32 = 0xFFFF_FFFF
}

/// Files over MTP, Android's built-in USB "File transfer" mode. No Developer options needed.
/// MTP addresses objects by numeric IDs; this class maps them to paths like "/Internal shared storage/DCIM".
final class MTPBackend: FileBackend, @unchecked Sendable {
    struct Storage {
        let id: UInt32
        let name: String
        let free: Int64
        let isRemovable: Bool
    }

    private struct Handle {
        let storage: UInt32
        let object: UInt32
    }

    let key: String
    let name: String
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private var storages: [Storage] = []
    private var index: [String: Handle] = [:]

    /// Must be called with `MTP.lock` held.
    init(key: String, device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, fallbackName: String) {
        self.key = key
        self.device = device
        let friendly = Self.take(LIBMTP_Get_Friendlyname(device))
        let model = Self.take(LIBMTP_Get_Modelname(device))
        self.name = [friendly, model].compactMap { $0 }.first { !$0.isEmpty } ?? fallbackName
        refreshStorages()
    }

    var cacheKey: String { "mtp:\(key)" }

    var rootPath: String {
        MTP.lock.lock(); defer { MTP.lock.unlock() }
        return storages.count == 1 ? "/" + storages[0].name : "/"
    }

    /// Must be called with `MTP.lock` held.
    func close() {
        if let device { LIBMTP_Release_Device(device) }
        device = nil
    }

    // MARK: Listing

    func list(_ path: String) throws -> [RemoteFile] {
        try withDevice { device in
            if path == "/" {
                refreshStorages()
                // Android hides storage until the phone is unlocked.
                guard !storages.isEmpty else { throw TetherError.phoneLocked }
                return storages.map { RemoteFile(directory: "/", name: $0.name, mode: 0o040755, size: 0, mtime: 0) }
            }
            let handle = try locate(path)
            forgetChildren(of: path)
            LIBMTP_Clear_Errorstack(device)

            var items: [RemoteFile] = []
            var node = LIBMTP_Get_Files_And_Folders(device, handle.storage, handle.object)
            if node == nil, let error = errorText(device) {
                throw TetherError.remote(error)
            }
            while let file = node {
                let name = file.pointee.filename.map { String(cString: $0) } ?? "Untitled"
                let isFolder = file.pointee.filetype == LIBMTP_FILETYPE_FOLDER
                let item = RemoteFile(
                    directory: path, name: name, mode: isFolder ? 0o040755 : 0o100644,
                    size: Int64(file.pointee.filesize), mtime: Int64(file.pointee.modificationdate))
                index[item.path] = Handle(storage: file.pointee.storage_id, object: file.pointee.item_id)
                items.append(item)
                node = file.pointee.next
                LIBMTP_destroy_file_t(file)
            }
            return items
        }
    }

    func exists(_ path: String) throws -> Bool {
        try withDevice { _ in
            let parent = RemotePath.parent(path)
            guard path != "/" else { return true }
            guard (try? list(parent)) != nil else { return false }
            return index[path] != nil
        }
    }

    // MARK: Transfers

    func download(_ file: RemoteFile, to url: URL, progress: TransferProgress) throws {
        try withDevice { device in
            let handle = try locate(file.path)
            let context = MTPProgressContext(progress)
            LIBMTP_Clear_Errorstack(device)
            let result = withExtendedLifetime(context) {
                LIBMTP_Get_File_To_File(device, handle.object, url.path, mtpProgressCallback,
                                        Unmanaged.passUnretained(context).toOpaque())
            }
            guard result == 0 else {
                try? FileManager.default.removeItem(at: url)
                if progress.isCancelled { throw CancellationError() }
                throw TetherError.remote(errorText(device) ?? "Couldn't copy “\(file.name)” from the phone.")
            }
        }
    }

    func upload(_ local: URL, to remotePath: String, modified: Date, progress: TransferProgress) throws {
        try withDevice { device in
            let parentPath = RemotePath.parent(remotePath)
            guard parentPath != "/" else {
                throw TetherError.remote("Open a storage location (like Internal shared storage) first, then copy files into it.")
            }
            let parent = try locate(parentPath)
            let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint64Value ?? 0

            guard let metadata = LIBMTP_new_file_t() else { throw TetherError.remote("Out of memory.") }
            defer { LIBMTP_destroy_file_t(metadata) }
            metadata.pointee.filename = strdup((remotePath as NSString).lastPathComponent)
            metadata.pointee.filesize = size
            metadata.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
            // 0xFFFFFFFF = storage root. (0 would make libmtp pick a "default" Music/Pictures folder.)
            metadata.pointee.parent_id = parent.object
            metadata.pointee.storage_id = parent.storage
            metadata.pointee.modificationdate = time_t(modified.timeIntervalSince1970)

            let context = MTPProgressContext(progress)
            LIBMTP_Clear_Errorstack(device)
            let result = withExtendedLifetime(context) {
                LIBMTP_Send_File_From_File(device, local.path, metadata, mtpProgressCallback,
                                           Unmanaged.passUnretained(context).toOpaque())
            }
            guard result == 0 else {
                if metadata.pointee.item_id != 0 { LIBMTP_Delete_Object(device, metadata.pointee.item_id) }
                if progress.isCancelled { throw CancellationError() }
                throw TetherError.remote(errorText(device) ?? "Couldn't copy “\(local.lastPathComponent)” to the phone.")
            }
            index[remotePath] = Handle(storage: parent.storage, object: metadata.pointee.item_id)
        }
    }

    // MARK: File operations

    func makeDirectories(_ paths: [String]) throws {
        for path in paths { try makeDirectory(path) }
    }

    private func makeDirectory(_ path: String) throws {
        try withDevice { device in
            if (try? locate(path)) != nil { return }
            let parentPath = RemotePath.parent(path)
            guard parentPath != "/" else {
                throw TetherError.remote("Folders can only be created inside a storage location.")
            }
            try makeDirectory(parentPath)
            let parent = try locate(parentPath)
            let name = strdup((path as NSString).lastPathComponent)
            defer { free(name) }
            LIBMTP_Clear_Errorstack(device)
            let id = LIBMTP_Create_Folder(device, name, parent.object, parent.storage)
            guard id != 0 else {
                throw TetherError.remote(errorText(device) ?? "Couldn't create “\((path as NSString).lastPathComponent)”.")
            }
            index[path] = Handle(storage: parent.storage, object: id)
        }
    }

    func rename(_ file: RemoteFile, to newName: String) throws {
        try withDevice { device in
            let handle = try locate(file.path)
            let destination = RemotePath.join(RemotePath.parent(file.path), newName)
            if (try? exists(destination)) == true {
                throw TetherError.remote("An item named “\(newName)” already exists.")
            }
            let name = strdup(newName)
            defer { free(name) }
            LIBMTP_Clear_Errorstack(device)
            guard LIBMTP_Set_Object_Filename(device, handle.object, name) == 0 else {
                throw TetherError.remote(errorText(device) ?? "Couldn't rename “\(file.name)”.")
            }
            forget(file.path)
        }
    }

    func delete(_ files: [RemoteFile]) throws {
        try withDevice { device in
            for file in files {
                try deleteObject(file.path, isDirectory: file.isDirectory, device: device)
                forget(file.path)
            }
        }
    }

    private func deleteObject(_ path: String, isDirectory: Bool, device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) throws {
        let handle = try locate(path)
        LIBMTP_Clear_Errorstack(device)
        if LIBMTP_Delete_Object(device, handle.object) == 0 { return }
        // Some phones refuse to delete non-empty folders; empty them first.
        guard isDirectory else {
            throw TetherError.remote(errorText(device) ?? "Couldn't delete “\((path as NSString).lastPathComponent)”.")
        }
        for child in try list(path) {
            try deleteObject(child.path, isDirectory: child.isDirectory, device: device)
        }
        LIBMTP_Clear_Errorstack(device)
        guard LIBMTP_Delete_Object(device, handle.object) == 0 else {
            throw TetherError.remote(errorText(device) ?? "Couldn't delete “\((path as NSString).lastPathComponent)”.")
        }
    }

    func freeSpace(at path: String) -> Int64? {
        try? withDevice { _ in
            refreshStorages()
            let storageName = path.split(separator: "/").first.map(String.init)
            return storages.first { $0.name == storageName }?.free
        }
    }

    func loadLocations() throws -> [StorageLocation] {
        try withDevice { _ in
            refreshStorages()
            var locations = storages.map {
                StorageLocation(name: $0.name, path: "/" + $0.name, systemImage: $0.isRemovable ? "sdcard" : "internaldrive")
            }
            if let primary = storages.first {
                locations = [locations[0]]
                    + StorageLocation.standard(root: "/" + primary.name, rootName: primary.name).dropFirst()
                    + locations.dropFirst()
            }
            return locations
        }
    }

    // MARK: Internals

    private func withDevice<T>(_ body: (UnsafeMutablePointer<LIBMTP_mtpdevice_t>) throws -> T) throws -> T {
        MTP.lock.lock()
        defer { MTP.lock.unlock() }
        guard let device else { throw TetherError.remote("The phone was disconnected.") }
        return try body(device)
    }

    /// Finds the MTP handle for a path, listing parent folders as needed.
    private func locate(_ path: String) throws -> Handle {
        if let handle = index[path] { return handle }
        let parent = RemotePath.parent(path)
        guard path != "/", parent != path else {
            throw TetherError.remote("Choose a storage location first.")
        }
        _ = try list(parent)
        if let handle = index[path] { return handle }
        throw TetherError.remote("“\((path as NSString).lastPathComponent)” is no longer on the phone.")
    }

    private func forget(_ path: String) {
        let prefix = path + "/"
        index = index.filter { $0.key != path && !$0.key.hasPrefix(prefix) }
    }

    private func forgetChildren(of path: String) {
        let prefix = path + "/"
        index = index.filter { key, _ in
            !(key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/"))
        }
    }

    private func refreshStorages() {
        guard let device else { return }
        LIBMTP_Get_Storage(device, 0)
        var result: [Storage] = []
        var used = Set<String>()
        var node = device.pointee.storage
        while let storage = node {
            var base = storage.pointee.StorageDescription.map { String(cString: $0) } ?? ""
            if base.isEmpty { base = "Storage" }
            base = base.replacingOccurrences(of: "/", with: "-")
            var unique = base
            var counter = 2
            while used.contains(unique) { unique = "\(base) (\(counter))"; counter += 1 }
            used.insert(unique)
            result.append(Storage(
                id: storage.pointee.id, name: unique,
                free: Int64(clamping: storage.pointee.FreeSpaceInBytes),
                isRemovable: storage.pointee.StorageType == 0x0004 /* removable RAM */ || storage.pointee.StorageType == 0x0002 /* removable ROM */))
            node = storage.pointee.next
        }
        storages = result
        for storage in result {
            index["/" + storage.name] = Handle(storage: storage.id, object: MTP.rootObject)
        }
    }

    private func errorText(_ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> String? {
        var messages: [String] = []
        var node = LIBMTP_Get_Errorstack(device)
        while let error = node {
            if let text = error.pointee.error_text { messages.append(String(cString: text)) }
            node = error.pointee.next
        }
        LIBMTP_Clear_Errorstack(device)
        return messages.last
    }

    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

private final class MTPProgressContext {
    let progress: TransferProgress
    var lastSent: UInt64 = 0
    init(_ progress: TransferProgress) { self.progress = progress }
}

/// Reports bytes to the transfer and returns non-zero to make libmtp abort when cancelled.
private let mtpProgressCallback: LIBMTP_progressfunc_t = { sent, _, data in
    guard let data else { return 0 }
    let context = Unmanaged<MTPProgressContext>.fromOpaque(data).takeUnretainedValue()
    if sent > context.lastSent {
        context.progress.add(Int(sent - context.lastSent))
        context.lastSent = sent
    }
    return context.progress.isCancelled ? 1 : 0
}

/// Detects phones plugged in with USB "File transfer" mode and keeps them open.
final class MTPMonitor: @unchecked Sendable {
    static let shared = MTPMonitor()

    private struct Failure {
        let name: String
        var lastAttempt: Date
    }

    private let stateLock = NSLock()
    private var backends: [String: MTPBackend] = [:]
    private var failures: [String: Failure] = [:]
    private var lastDevices: [Device] = []
    private var lastDaemonKill = Date.distantPast

    func backend(key: String) -> MTPBackend? {
        stateLock.lock(); defer { stateLock.unlock() }
        return backends[key]
    }

    /// Blocking; call from a background thread. Skips the USB scan while a transfer is using MTP.
    func poll() -> [Device] {
        MTP.initialize()
        guard MTP.lock.try() else {
            stateLock.lock(); defer { stateLock.unlock() }
            return lastDevices
        }
        defer { MTP.lock.unlock() }

        var raws: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let status = LIBMTP_Detect_Raw_Devices(&raws, &count)
        defer { free(raws) }

        var seen = Set<String>()
        if status == LIBMTP_ERROR_NONE, let raws {
            for index in 0..<Int(count) {
                var raw = raws[index]
                let key = "\(raw.bus_location)-\(raw.devnum)"
                seen.insert(key)
                if backend(key: key) != nil { continue }

                let vendor = raw.device_entry.vendor.map { String(cString: $0) } ?? ""
                let product = raw.device_entry.product.map { String(cString: $0) } ?? ""
                let fallbackName = [vendor, product].filter { !$0.isEmpty && $0 != "Unknown" }.joined(separator: " ")

                stateLock.lock()
                let failure = failures[key]
                stateLock.unlock()
                if let failure, Date().timeIntervalSince(failure.lastAttempt) < 8 { continue }

                if let device = open(&raw) {
                    let backend = MTPBackend(key: key, device: device, fallbackName: fallbackName.isEmpty ? "Android phone" : fallbackName)
                    stateLock.lock()
                    backends[key] = backend
                    failures[key] = nil
                    stateLock.unlock()
                } else {
                    stateLock.lock()
                    failures[key] = Failure(name: fallbackName.isEmpty ? "Android phone" : fallbackName, lastAttempt: Date())
                    stateLock.unlock()
                }
            }
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        for (key, backend) in backends where !seen.contains(key) {
            backend.close()
            backends[key] = nil
        }
        failures = failures.filter { seen.contains($0.key) }

        lastDevices = backends.values.sorted { $0.key < $1.key }.map {
            Device(kind: .mtp, serial: $0.key, state: "device", model: $0.name)
        } + failures.sorted { $0.key < $1.key }.map {
            Device(kind: .mtp, serial: $0.key, state: "unavailable", model: $0.value.name)
        }
        return lastDevices
    }

    private func open(_ raw: inout LIBMTP_raw_device_t) -> UnsafeMutablePointer<LIBMTP_mtpdevice_t>? {
        if let device = LIBMTP_Open_Raw_Device_Uncached(&raw) { return device }
        // macOS's camera daemon (used by Image Capture/Photos) often claims Android phones.
        // It's a per-user agent that launchd restarts on demand, so stopping it is harmless.
        guard Date().timeIntervalSince(lastDaemonKill) > 5 else { return nil }
        lastDaemonKill = Date()
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killer.arguments = ["-9", "ptpcamerad"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
        killer.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        return LIBMTP_Open_Raw_Device_Uncached(&raw)
    }
}
