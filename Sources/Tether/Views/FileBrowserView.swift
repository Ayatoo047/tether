import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    let device: Device
    @ObservedObject var model: BrowserModel
    @EnvironmentObject private var transfers: TransferManager

    @State private var isDropTargeted = false
    @State private var showTransfers = false
    @State private var pendingDelete: [RemoteFile] = []
    @State private var showDeleteConfirmation = false
    @State private var renameTarget: RemoteFile?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        let items = model.visibleEntries
        table(items)
            .overlay { overlay(isEmpty: items.isEmpty) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BrowserStatusBar(model: model, itemCount: items.count)
            }
            .navigationTitle(model.displayTitle)
            .navigationSubtitle(device.displayName)
            .searchable(text: $model.filter, placement: .toolbar, prompt: "Filter this folder")
            .toolbar { toolbar }
            .quickLookPreview($model.previewURL)
            .task { if !model.hasLoaded { model.reload() } }
            .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirmation, presenting: pendingDelete) { files in
                Button("Delete", role: .destructive) { model.delete(files) }
            } message: { _ in
                Text("This permanently removes them from your phone. You can't undo this.")
            }
            .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") { if let file = renameTarget { model.rename(file, to: renameText) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") { model.createFolder(named: newFolderName) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Something went wrong", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.alertMessage ?? "")
            }
    }

    // MARK: Table

    private func table(_ items: [RemoteFile]) -> some View {
        Table(of: RemoteFile.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { file in
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: file))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(file.isHidden ? 0.55 : 1)
                }
            }
            .width(min: 180, ideal: 340)

            TableColumn("Date Modified", value: \.modified) { file in
                Text(file.modified.timeIntervalSince1970 > 0 ? file.modified.formatted(date: .abbreviated, time: .shortened) : "--")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Size", value: \.size) { file in
                Text(file.isDirectory ? "--" : file.size.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 85)

            TableColumn("Kind", value: \.kind) { file in
                Text(file.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        } rows: {
            ForEach(items) { file in
                TableRow(file)
                    .draggable(RemoteFileDragItem(backend: model.backend, file: file))
            }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            contextMenu(model.files(for: ids))
        } primaryAction: { ids in
            let files = model.files(for: ids)
            if files.count == 1, let file = files.first {
                model.open(file)
            } else {
                model.download(files.filter { !$0.isDirectory })
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let localFiles = urls.filter { $0.isFileURL && !AppPaths.isInsideTempRoot($0) }
            guard !localFiles.isEmpty else { return false }
            model.upload(localFiles)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onKeyPress(.space) {
            guard let file = model.selectedFiles.first(where: { !$0.isDirectory }) else { return .ignored }
            model.quickLook(file)
            return .handled
        }
        .onDeleteCommand { requestDelete(model.selectedFiles) }
    }

    @ViewBuilder
    private func overlay(isEmpty: Bool) -> some View {
        ZStack {
            if let error = model.loadError, !model.isLoading {
                ContentUnavailableView {
                    Label("Couldn't open this folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { model.reload() }
                }
            } else if isEmpty && model.isLoading {
                ProgressView("Loading…")
            } else if isEmpty && model.hasLoaded {
                ContentUnavailableView {
                    Label(model.filter.isEmpty ? "This folder is empty" : "No matches", systemImage: model.filter.isEmpty ? "folder" : "magnifyingglass")
                } description: {
                    Text(model.filter.isEmpty ? "Drag files from Finder here to copy them to your phone." : "Nothing in this folder matches “\(model.filter)”.")
                }
            }

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        Label("Copy to “\(model.displayTitle)”", systemImage: "arrow.down.doc")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ files: [RemoteFile]) -> some View {
        if files.isEmpty {
            Button("New Folder…") { beginNewFolder() }
            Button("Upload Files…") { chooseUpload() }
            Divider()
            Button("Refresh") { model.reload() }
        } else {
            if files.count == 1, let file = files.first {
                if file.isDirectory {
                    Button("Open") { model.open(file) }
                    Button("Upload Into This Folder…") { chooseUpload(into: file.path) }
                } else {
                    Button("Quick Look") { model.quickLook(file) }
                    Button("Open With Default App") { model.openExternally(file) }
                }
                Divider()
            }
            Button("Download") { model.download(files) }
            Button("Download To…") { chooseDownload(files) }
            Divider()
            if files.count == 1, let file = files.first {
                Button("Rename…") { beginRename(file) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
                Divider()
            }
            Button("Delete…", role: .destructive) { requestDelete(files) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
            Button { model.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.turn.left.up") }
                .disabled(!model.canGoUp)
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Enclosing folder")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { beginNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New folder")
            Button { chooseUpload() } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("u", modifiers: .command)
                .help("Copy files from this Mac to the phone")
            Button { model.download(model.selectedFiles) } label: { Label("Download", systemImage: "square.and.arrow.down") }
                .disabled(model.selection.isEmpty)
                .keyboardShortcut("d", modifiers: .command)
                .help("Copy the selection to your Downloads folder")
            Button { requestDelete(model.selectedFiles) } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.selection.isEmpty)
                .help("Delete from phone")
            Button { model.showHidden.toggle() } label: {
                Label("Hidden Files", systemImage: model.showHidden ? "eye" : "eye.slash")
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .help(model.showHidden ? "Hide hidden files" : "Show hidden files")
            Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh")
            Button { showTransfers.toggle() } label: {
                if transfers.activeTransfers.isEmpty {
                    Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
                } else {
                    ProgressView(value: transfers.overallFraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }
            .help("Transfers")
            .popover(isPresented: $showTransfers, arrowEdge: .bottom) {
                TransfersView()
            }
        }
    }

    // MARK: Actions

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].name)”?" : "Delete \(pendingDelete.count) items?"
    }

    private func requestDelete(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        pendingDelete = files
        showDeleteConfirmation = true
    }

    private func beginRename(_ file: RemoteFile) {
        renameText = file.name
        renameTarget = file
    }

    private func beginNewFolder() {
        newFolderName = "untitled folder"
        showNewFolder = true
    }

    private func chooseUpload(into directory: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        panel.message = "Choose files or folders to copy to “\(directory.map { ($0 as NSString).lastPathComponent } ?? model.displayTitle)”"
        if panel.runModal() == .OK {
            model.upload(panel.urls, into: directory)
        }
    }

    private func chooseDownload(_ files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.directoryURL = AppSettings.downloadFolder
        if panel.runModal() == .OK, let url = panel.url {
            model.download(files, to: url)
        }
    }
}

struct BrowserStatusBar: View {
    @ObservedObject var model: BrowserModel
    @EnvironmentObject private var transfers: TransferManager
    let itemCount: Int

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        let crumbs = model.breadcrumbs
                        ForEach(crumbs.indices, id: \.self) { index in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                model.navigate(crumbs[index].path)
                            } label: {
                                HStack(spacing: 3) {
                                    if index == 0 { Image(systemName: "internaldrive") }
                                    Text(crumbs[index].title)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                        }
                    }
                }

                Spacer(minLength: 8)

                if let active = transfers.activeTransfers.first {
                    HStack(spacing: 6) {
                        ProgressView(value: transfers.overallFraction)
                            .frame(width: 80)
                        Text(transfers.activeTransfers.count == 1
                             ? active.title
                             : "\(transfers.activeTransfers.count) transfers")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160, alignment: .leading)
                    }
                }

                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .background(.bar)
    }

    private var summary: String {
        var parts = ["\(itemCount) item\(itemCount == 1 ? "" : "s")"]
        if !model.selection.isEmpty { parts[0] += ", \(model.selection.count) selected" }
        if let free = model.freeSpace { parts.append("\(free.formatted(.byteCount(style: .file))) available") }
        return parts.joined(separator: " · ")
    }
}

/// Lets rows be dragged straight into Finder; the file is pulled from the phone on drop.
struct RemoteFileDragItem: Transferable {
    let backend: FileBackend
    let file: RemoteFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try await TransferManager.shared.exportForDrag(backend: item.backend, file: item.file))
        }
        .exportingCondition { !$0.file.isDirectory }

        FileRepresentation(exportedContentType: .folder) { item in
            SentTransferredFile(try await TransferManager.shared.exportForDrag(backend: item.backend, file: item.file))
        }
        .exportingCondition { $0.file.isDirectory }
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for file: RemoteFile) -> NSImage {
        let key = file.isDirectory ? "/folder" : file.fileExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = file.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
