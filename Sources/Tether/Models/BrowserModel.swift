import AppKit
import Foundation

@MainActor
final class BrowserModel: ObservableObject {
    let backend: FileBackend

    @Published private(set) var path: String
    @Published private(set) var entries: [RemoteFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var freeSpace: Int64?
    @Published var selection = Set<RemoteFile.ID>()
    @Published var sortOrder = [KeyPathComparator(\RemoteFile.name, comparator: .localizedStandard)]
    @Published var filter = ""
    @Published var previewURL: URL?
    @Published var alertMessage: String?
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHiddenFiles") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHiddenFiles") }
    }

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var loadTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init(backend: FileBackend) {
        self.backend = backend
        self.path = backend.rootPath
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { path != "/" }

    var visibleEntries: [RemoteFile] {
        var items = entries
        if !showHidden { items.removeAll(where: \.isHidden) }
        if !filter.isEmpty { items = items.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        items.sort(using: sortOrder)
        return items.filter(\.isDirectory) + items.filter { !$0.isDirectory }
    }

    var selectedFiles: [RemoteFile] { files(for: selection) }

    func files(for ids: Set<RemoteFile.ID>) -> [RemoteFile] {
        entries.filter { ids.contains($0.id) }
    }

    // MARK: Navigation

    func navigate(_ target: String) { load(target, recordHistory: true, autoDescend: false) }
    func reload() { load(path, recordHistory: false, autoDescend: !hasLoaded) }
    func goUp() { navigate(RemotePath.parent(path)) }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(path)
        load(target, recordHistory: false, autoDescend: false)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(path)
        load(target, recordHistory: false, autoDescend: false)
    }

    private func load(_ target: String, recordHistory: Bool, autoDescend: Bool) {
        loadTask?.cancel()
        retryTask?.cancel()
        isLoading = true
        let backend = backend
        let previous = path
        loadTask = Task {
            let result = await Task.detached { Result { try backend.list(target) } }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            switch result {
            case .success(let items):
                // A phone with a single storage: skip the storage picker.
                if autoDescend, target == "/", items.count == 1, items[0].isDirectory {
                    load(items[0].path, recordHistory: false, autoDescend: false)
                    return
                }
                hasLoaded = true
                if recordHistory && target != previous {
                    backStack.append(previous)
                    forwardStack.removeAll()
                }
                if target != path {
                    selection.removeAll()
                    filter = ""
                }
                path = target
                entries = items
                loadError = nil
                refreshFreeSpace()
            case .failure(let error):
                hasLoaded = true
                loadError = error.localizedDescription
                if case TetherError.phoneLocked = error {
                    // Keep checking until the phone is unlocked.
                    retryTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        load(target, recordHistory: recordHistory, autoDescend: true)
                    }
                }
            }
        }
    }

    private func refreshFreeSpace() {
        let backend = backend
        let path = path
        Task {
            freeSpace = await Task.detached { backend.freeSpace(at: path) }.value
        }
    }

    var breadcrumbs: [(title: String, path: String)] { backend.breadcrumbs(for: path) }
    var displayTitle: String { breadcrumbs.last?.title ?? path }

    // MARK: Opening & previewing

    func open(_ file: RemoteFile) {
        if file.isDirectory { navigate(file.path) } else { quickLook(file) }
    }

    func quickLook(_ file: RemoteFile) {
        guard !file.isDirectory else { return }
        if previewURL != nil { previewURL = nil; return }
        Task {
            do {
                previewURL = try await TransferManager.shared.cachedCopy(backend: backend, file: file)
            } catch is CancellationError {
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func openExternally(_ file: RemoteFile) {
        Task {
            do {
                let url = try await TransferManager.shared.cachedCopy(backend: backend, file: file)
                NSWorkspace.shared.open(url)
            } catch is CancellationError {
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    // MARK: Transfers

    func download(_ files: [RemoteFile], to directory: URL? = nil) {
        guard !files.isEmpty else { return }
        TransferManager.shared.download(backend: backend, files: files, to: directory ?? AppSettings.downloadFolder)
    }

    func upload(_ urls: [URL], into remoteDirectory: String? = nil) {
        guard !urls.isEmpty else { return }
        let target = remoteDirectory ?? path
        guard target != "/" || backend is ADBBackend else {
            alertMessage = "Open a storage location (like Internal shared storage) first, then copy files into it."
            return
        }
        TransferManager.shared.upload(backend: backend, urls: urls, to: target) { [weak self] in
            guard let self, self.path == target else { return }
            self.reload()
        }
    }

    // MARK: File operations

    func createFolder(named name: String) {
        guard let name = validated(name) else { return }
        let target = RemotePath.join(path, name)
        perform { backend in try backend.makeDirectories([target]) }
    }

    func rename(_ file: RemoteFile, to newName: String) {
        guard let newName = validated(newName), newName != file.name else { return }
        perform { backend in try backend.rename(file, to: newName) }
    }

    func delete(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        perform { backend in try backend.delete(files) }
    }

    private func validated(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            alertMessage = "“\(trimmed)” isn't a valid name."
            return nil
        }
        return trimmed
    }

    private func perform(_ operation: @escaping @Sendable (FileBackend) throws -> Void) {
        let backend = backend
        Task {
            do {
                try await Task.detached { try operation(backend) }.value
            } catch {
                alertMessage = error.localizedDescription
            }
            reload()
        }
    }
}
