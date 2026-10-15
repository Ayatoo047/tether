import AppKit
import CryptoKit
import Foundation

/// Thread-safe progress counters written by a transfer's worker thread and sampled by the UI.
final class TransferProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    private var done: Int64 = 0
    private var current: String?
    private var skipped = 0
    private var cancelled = false
    private var socket: ADBSocket?

    func setTotal(_ value: Int64) { lock.lock(); total = value; lock.unlock() }
    func add(_ bytes: Int) { lock.lock(); done += Int64(bytes); lock.unlock() }
    func setCurrent(_ name: String?) { lock.lock(); current = name; lock.unlock() }
    func noteSkipped() { lock.lock(); skipped += 1; lock.unlock() }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func snapshot() -> (total: Int64, done: Int64, current: String?, skipped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (total, done, current, skipped)
    }

    func attach(_ socket: ADBSocket) {
        lock.lock()
        self.socket = socket
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { socket.shutdown() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let socket = socket
        lock.unlock()
        socket?.shutdown()
    }

    func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }
}

typealias TransferWork = @Sendable (TransferProgress) throws -> URL?

@MainActor
final class Transfer: ObservableObject, Identifiable {
    enum Kind { case download, upload, preview }

    enum State: Equatable {
        case queued, running, completed, failed(String), cancelled
        var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            case .queued, .running: return false
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let destination: String
    let progress = TransferProgress()
    fileprivate let work: TransferWork
    fileprivate var waiters: [(Result<URL?, Error>) -> Void] = []
    fileprivate var onFinish: (() -> Void)?

    @Published fileprivate(set) var state: State = .queued
    @Published fileprivate(set) var totalBytes: Int64 = 0
    @Published fileprivate(set) var transferredBytes: Int64 = 0
    @Published fileprivate(set) var bytesPerSecond: Double = 0
    @Published fileprivate(set) var currentItem: String?
    @Published fileprivate(set) var skippedCount = 0
    @Published fileprivate(set) var resultURL: URL?

    private var lastSample: (time: Date, bytes: Int64)?

    fileprivate init(kind: Kind, title: String, destination: String, work: @escaping TransferWork) {
        self.kind = kind
        self.title = title
        self.destination = destination
        self.work = work
    }

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(transferredBytes) / Double(totalBytes)) : 0
    }

    fileprivate func sample() {
        let snapshot = progress.snapshot()
        totalBytes = snapshot.total
        transferredBytes = snapshot.done
        currentItem = snapshot.current
        skippedCount = snapshot.skipped

        let now = Date()
        if let last = lastSample {
            let elapsed = now.timeIntervalSince(last.time)
            guard elapsed >= 0.5 else { return }
            let instant = Double(snapshot.done - last.bytes) / elapsed
            bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.6 + instant * 0.4
        }
        lastSample = (now, snapshot.done)
    }
}

@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    @Published private(set) var transfers: [Transfer] = []
    private var runningCount = 0
    private let maxConcurrent = 3
    private var ticker: Task<Void, Never>?

    var activeTransfers: [Transfer] { transfers.filter { !$0.state.isFinished } }

    var overallFraction: Double {
        let active = activeTransfers
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = active.reduce(Int64(0)) { $0 + $1.transferredBytes }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    // MARK: Public operations

    func download(backend: FileBackend, files: [RemoteFile], to directory: URL) {
        for file in files {
            enqueue(.download, title: file.name, destination: directory.lastPathComponent,
                    work: TransferJobs.download(backend: backend, file: file, to: directory))
        }
    }

    func upload(backend: FileBackend, urls: [URL], to remoteDirectory: String, onFinish: @escaping () -> Void) {
        let folderName = (remoteDirectory as NSString).lastPathComponent
        for url in urls {
            let transfer = enqueue(.upload, title: url.lastPathComponent, destination: folderName,
                                   work: TransferJobs.upload(backend: backend, local: url, remoteDirectory: remoteDirectory))
            transfer.onFinish = onFinish
        }
    }

    /// Downloads a file into the preview cache (or returns the cached copy).
    func cachedCopy(backend: FileBackend, file: RemoteFile) async throws -> URL {
        let destination = TransferJobs.cacheURL(key: backend.cacheKey, file: file)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let transfer = enqueue(.preview, title: file.name, destination: "Preview",
                               work: TransferJobs.fetch(backend: backend, file: file, to: destination))
        guard let url = try await wait(for: transfer) else { throw TetherError.protocolError("no file") }
        return url
    }

    /// Downloads a file or folder to a temporary location for dragging into Finder.
    func exportForDrag(backend: FileBackend, file: RemoteFile) async throws -> URL {
        let directory = AppPaths.drags.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let transfer = enqueue(.download, title: file.name, destination: "Finder",
                               work: TransferJobs.download(backend: backend, file: file, to: directory))
        guard let url = try await wait(for: transfer) else { throw TetherError.protocolError("no file") }
        return url
    }

    func cancel(_ transfer: Transfer) {
        switch transfer.state {
        case .queued: finish(transfer, .failure(CancellationError()))
        case .running: transfer.progress.cancel()
        default: break
        }
    }

    func cancelAll() {
        activeTransfers.forEach(cancel)
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isFinished }
    }

    // MARK: Queue

    @discardableResult
    private func enqueue(_ kind: Transfer.Kind, title: String, destination: String, work: @escaping TransferWork) -> Transfer {
        let transfer = Transfer(kind: kind, title: title, destination: destination, work: work)
        transfers.append(transfer)
        pump()
        return transfer
    }

    private func wait(for transfer: Transfer) async throws -> URL? {
        switch transfer.state {
        case .completed: return transfer.resultURL
        case .failed(let message): throw TetherError.remote(message)
        case .cancelled: throw CancellationError()
        case .queued, .running:
            return try await withCheckedThrowingContinuation { continuation in
                transfer.waiters.append { continuation.resume(with: $0) }
            }
        }
    }

    private func pump() {
        while runningCount < maxConcurrent, let next = transfers.first(where: { $0.state == .queued }) {
            runningCount += 1
            next.state = .running
            let work = next.work
            let progress = next.progress
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result<URL?, Error> { try work(progress) }
                }.value
                self.runningCount -= 1
                self.finish(next, result)
                self.pump()
            }
        }
        startTicker()
    }

    private func finish(_ transfer: Transfer, _ result: Result<URL?, Error>) {
        guard !transfer.state.isFinished else { return }
        transfer.sample()
        let outcome: Result<URL?, Error>
        switch result {
        case .success(let url):
            transfer.state = .completed
            transfer.resultURL = url
            transfer.transferredBytes = transfer.totalBytes
            outcome = .success(url)
        case .failure(let error):
            if error is CancellationError || transfer.progress.isCancelled {
                transfer.state = .cancelled
                outcome = .failure(CancellationError())
            } else {
                transfer.state = .failed(error.localizedDescription)
                outcome = .failure(error)
            }
        }
        let waiters = transfer.waiters
        transfer.waiters = []
        waiters.forEach { $0(outcome) }
        transfer.onFinish?()
        transfer.onFinish = nil
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let running = self.transfers.filter { $0.state == .running }
                if running.isEmpty && self.runningCount == 0 {
                    self.ticker = nil
                    self.objectWillChange.send()
                    return
                }
                running.forEach { $0.sample() }
                self.objectWillChange.send()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// Builders for the blocking work each transfer performs on a background thread.
enum TransferJobs {
    static func download(backend: FileBackend, file: RemoteFile, to directory: URL) -> TransferWork {
        { progress in
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = uniqueLocalURL(directory.appendingPathComponent(file.name))
            do {
                if file.isDirectory {
                    let tree = try backend.walk(file.path)
                    progress.setTotal(tree.reduce(0) { $1.file.isDirectory ? $0 : $0 + $1.file.size })
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    for item in tree {
                        try progress.checkCancelled()
                        let target = destination.appendingPathComponent(item.relative)
                        if item.file.isDirectory {
                            try fm.createDirectory(at: target, withIntermediateDirectories: true)
                            continue
                        }
                        progress.setCurrent(item.relative)
                        do {
                            try backend.download(item.file, to: target, progress: progress)
                            setModified(target, item.file.modified)
                        } catch TetherError.remote {
                            // Unreadable file (e.g. permission denied): skip it, keep going.
                            try? fm.removeItem(at: target)
                            progress.noteSkipped()
                        }
                    }
                } else {
                    progress.setTotal(file.size)
                    try backend.download(file, to: destination, progress: progress)
                    setModified(destination, file.modified)
                }
            } catch {
                try? fm.removeItem(at: destination)
                throw error
            }
            return destination
        }
    }

    static func fetch(backend: FileBackend, file: RemoteFile, to destination: URL) -> TransferWork {
        { progress in
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.deletingLastPathComponent().appendingPathComponent(".partial-" + file.name)
            progress.setTotal(file.size)
            do {
                try backend.download(file, to: partial, progress: progress)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: partial, to: destination)
            } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
            return destination
        }
    }

    static func upload(backend: FileBackend, local: URL, remoteDirectory: String) -> TransferWork {
        { progress in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: local.path, isDirectory: &isDirectory) else {
                throw TetherError.remote("“\(local.lastPathComponent)” no longer exists.")
            }
            let remoteRoot = RemotePath.join(remoteDirectory, try backend.availableName(local.lastPathComponent, in: remoteDirectory))

            if isDirectory.boolValue {
                var directories = [remoteRoot]
                var files: [(local: URL, remote: String, size: Int64, modified: Date)] = []
                let enumerator = fm.enumerator(atPath: local.path)
                while let relative = enumerator?.nextObject() as? String {
                    if (relative as NSString).lastPathComponent == ".DS_Store" { continue }
                    let attributes = enumerator?.fileAttributes ?? [:]
                    let type = attributes[.type] as? FileAttributeType
                    let remote = RemotePath.join(remoteRoot, relative)
                    if type == .typeDirectory {
                        directories.append(remote)
                    } else if type == .typeRegular {
                        files.append((
                            local.appendingPathComponent(relative), remote,
                            (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                            attributes[.modificationDate] as? Date ?? Date()))
                    }
                }
                progress.setTotal(files.reduce(0) { $0 + $1.size })
                try progress.checkCancelled()
                try backend.makeDirectories(directories)
                for file in files {
                    try progress.checkCancelled()
                    progress.setCurrent((file.remote as NSString).lastPathComponent)
                    try backend.upload(file.local, to: file.remote, modified: file.modified, progress: progress)
                }
            } else {
                let attributes = try fm.attributesOfItem(atPath: local.path)
                progress.setTotal((attributes[.size] as? NSNumber)?.int64Value ?? 0)
                try backend.upload(local, to: remoteRoot, modified: attributes[.modificationDate] as? Date ?? Date(), progress: progress)
            }
            return nil
        }
    }

    static func cacheURL(key: String, file: RemoteFile) -> URL {
        let identity = "\(key)|\(file.path)|\(file.size)|\(file.modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return AppPaths.previews.appendingPathComponent(digest, isDirectory: true).appendingPathComponent(file.name)
    }

    static func uniqueLocalURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func setModified(_ url: URL, _ date: Date) {
        guard date.timeIntervalSince1970 > 0 else { return }
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
