import AppKit
import SwiftUI

struct TransfersView: View {
    @EnvironmentObject private var manager: TransferManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                if !manager.activeTransfers.isEmpty {
                    Button("Stop All") { manager.cancelAll() }
                }
                Button("Clear") { manager.clearFinished() }
                    .disabled(!manager.transfers.contains { $0.state.isFinished })
            }
            .padding(12)
            Divider()
            if manager.transfers.isEmpty {
                Text("Files you copy to or from your phone appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .padding(.horizontal)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.transfers.reversed()) { transfer in
                            TransferRow(transfer: transfer)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 400)
    }
}

struct TransferRow: View {
    @ObservedObject var transfer: Transfer
    @EnvironmentObject private var manager: TransferManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.state == .running {
                    ProgressView(value: transfer.fraction)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if !transfer.state.isFinished {
                Button { manager.cancel(transfer) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Stop")
            } else if transfer.state == .completed, transfer.kind == .download, let url = transfer.resultURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var icon: String {
        switch transfer.kind {
        case .download: return "arrow.down.circle.fill"
        case .upload: return "arrow.up.circle.fill"
        case .preview: return "eye.circle.fill"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .failed: return .red
        case .cancelled: return .secondary
        case .completed: return .green
        default: return .accentColor
        }
    }

    private var isFailure: Bool {
        if case .failed = transfer.state { return true }
        return false
    }

    private var status: String {
        let total = transfer.totalBytes.formatted(.byteCount(style: .file))
        let direction = transfer.kind == .upload ? "to" : "from"
        switch transfer.state {
        case .queued:
            return "Waiting…"
        case .running:
            let done = transfer.transferredBytes.formatted(.byteCount(style: .file))
            var text = "\(done) of \(total)"
            if transfer.bytesPerSecond > 0 {
                text += " — \(Int64(transfer.bytesPerSecond).formatted(.byteCount(style: .file)))/s"
            }
            if let current = transfer.currentItem { text += "\n\(current)" }
            return text
        case .completed:
            var text = transfer.kind == .preview ? "Ready" : "Copied \(total) \(direction) phone"
            if transfer.skippedCount > 0 { text += " — \(transfer.skippedCount) unreadable item(s) skipped" }
            return text
        case .failed(let message):
            return message
        case .cancelled:
            return "Stopped"
        }
    }
}
