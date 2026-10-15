import AppKit
import CoreImage.CIFilterBuiltins
import QuickLook
import SwiftUI

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct WebLinkView: View {
    @ObservedObject private var server = WebLinkServer.shared
    @State private var isDropTargeted = false
    @State private var previewURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectCard
                HStack(alignment: .top, spacing: 20) {
                    sharedCard
                    receivedCard
                }
                troubleshooting
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Browser Link")
        .navigationSubtitle("Wi-Fi, nothing to install on the phone")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if server.isRunning {
                    Button { server.turnOff() } label: { Label("Stop Link", systemImage: "stop.circle") }
                        .help("Stop the link so the phone can no longer reach this Mac")
                } else {
                    Button { server.start() } label: { Label("Start Link", systemImage: "play.circle") }
                }
            }
        }
        .quickLookPreview($previewURL)
        .onAppear {
            server.start()
            server.refreshAddress()
        }
    }

    // MARK: Cards

    private var connectCard: some View {
        HStack(alignment: .center, spacing: 28) {
            ZStack {
                if server.isRunning, let url = server.url, let image = QRCode.image(url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 190, height: 190)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .frame(width: 210, height: 210)
                        .overlay {
                            if server.isRunning {
                                Text("No network").foregroundStyle(.secondary)
                            } else {
                                Button("Start Link") { server.start() }
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Swap files over Wi-Fi with any phone")
                    .font(.title2.bold())
                StepLine(number: 1, text: "Connect the phone to the same Wi-Fi network as this Mac.")
                StepLine(number: 2, text: "Scan this code with the phone's camera and open the link.")
                StepLine(number: 3, text: "Tap **Choose photos & files** to send to the Mac, or save files you share from here.")

                if let url = server.url, server.isRunning {
                    HStack(spacing: 8) {
                        Text(url.absoluteString)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy link")
                    }
                    .padding(.top, 4)
                }

                if let error = server.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if let active = server.lastPhoneActivity, Date().timeIntervalSince(active) < 10 {
                    Label("Phone connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }

                Text("The phone starts each transfer. To browse the phone's own files from this Mac, use a USB cable in File transfer mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private var sharedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Shared with the phone", systemImage: "arrow.up.forward.app")
                    .font(.headline)
                Spacer()
                Button("Add Files…") { chooseFiles() }
            }
            if server.shared.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Drop files here. They'll appear on the phone's page, ready to save.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ForEach(server.shared) { file in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                            .resizable()
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Text(file.size.formatted(.byteCount(style: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { server.unshare(file) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Stop sharing")
                    }
                    Divider()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            server.share(files)
            return !files.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    private var receivedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Received from the phone", systemImage: "arrow.down.backward.square")
                    .font(.headline)
                Spacer()
                Button("Clear") { server.clearReceived() }
                    .disabled(!server.received.contains { $0.state != .receiving })
            }
            if server.received.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("Files sent from the phone are saved to \(AppSettings.downloadFolder.lastPathComponent).")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ForEach(server.received) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.state == .failed ? "xmark.octagon.fill" : file.state == .done ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(file.state == .failed ? Color.red : file.state == .done ? Color.green : Color.accentColor)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            if file.state == .receiving {
                                ProgressView(value: file.total > 0 ? Double(file.received) / Double(file.total) : 0)
                            }
                            Text(status(file)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if file.state == .done {
                            Button { previewURL = file.url } label: { Image(systemName: "eye") }
                                .buttonStyle(.borderless)
                                .help("Quick Look")
                            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                        }
                    }
                    Divider()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private var troubleshooting: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("That error means the phone can't reach this Mac on the network, even if both have internet.")
                tip("Same network?", "On the phone, open Wi-Fi settings, tap the connected network and check its IP address. It should start like this Mac's (**\(server.address.map { $0.split(separator: ".").prefix(3).joined(separator: ".") + ".x" } ?? "—")**). Guest networks and some mesh or extender networks are separate.")
                tip("Router blocking devices from each other?", "Many routers have **client isolation** (also called AP isolation) turned on, especially on guest networks. Turn it off in the router's settings, or use the next tip.")
                tip("Works everywhere: the phone's hotspot", "On the phone, turn on **Hotspot** and join it from this Mac. The QR code updates automatically; scan it again. Transfers stay between the two devices and don't use mobile data.")
            }
            .font(.callout)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label("Phone says “site can't be reached” or ERR_ADDRESS_UNREACHABLE?", systemImage: "questionmark.circle")
                .font(.callout.weight(.medium))
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private func tip(_ title: String, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(body).foregroundStyle(.secondary)
        }
    }

    private func status(_ file: WebLinkServer.ReceivedFile) -> String {
        switch file.state {
        case .receiving:
            return "\(file.received.formatted(.byteCount(style: .file))) of \(file.total.formatted(.byteCount(style: .file)))"
        case .done:
            return file.total.formatted(.byteCount(style: .file))
        case .failed:
            return "Didn't finish (the phone may have left the page)"
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        if panel.runModal() == .OK { server.share(panel.urls) }
    }
}

struct StepLine: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
