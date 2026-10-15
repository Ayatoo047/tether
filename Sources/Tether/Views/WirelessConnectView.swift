import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Android 11+ "Wireless debugging" pairing: the phone scans a QR code (or the user types
/// a 6-digit code), adb pairs over TLS, then connects to the phone's advertised mDNS service.
@MainActor
final class WirelessPairing: ObservableObject {
    enum Status: Equatable {
        case idle
        case waitingForScan
        case pairing
        case connecting
        case connected(String)
        case paired(String)
        case failed(String)
    }

    @Published var status: Status = .idle
    let serviceName = "tether-" + WirelessPairing.randomString(length: 6)
    let password = WirelessPairing.randomString(length: 10)
    private var task: Task<Void, Never>?

    var qrPayload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }

    func startQR() {
        stop()
        status = .waitingForScan
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let services = await ADBTool.mdnsServices()
                if let service = services.first(where: { $0.isPairing && $0.name == self.serviceName }) {
                    await self.pair(address: service.address, code: self.password)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func pairManually(address: String, code: String) {
        stop()
        let address = address.trimmingCharacters(in: .whitespaces)
        let code = code.trimmingCharacters(in: .whitespaces)
        task = Task { await pair(address: address, code: code) }
    }

    func connectManually(address: String) {
        stop()
        var address = address.trimmingCharacters(in: .whitespaces)
        if !address.contains(":") { address += ":5555" }
        status = .connecting
        task = Task {
            do {
                try await ADBTool.connect(address)
                status = .connected("Connected to \(address).")
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if status == .waitingForScan { status = .idle }
    }

    private func pair(address: String, code: String) async {
        status = .pairing
        do {
            let guid = try await ADBTool.pair(address: address, code: code)
            status = .connecting
            let host = Self.host(of: address)
            for _ in 0..<12 {
                if Task.isCancelled { return }
                if let device = await connectedDevice(guid: guid, host: host) {
                    status = .connected("Connected to \(device.displayName).")
                    return
                }
                let targets = await ADBTool.mdnsServices().filter {
                    $0.isConnect && ($0.name == guid || Self.host(of: $0.address) == host)
                }
                for target in targets {
                    if (try? await ADBTool.connect(target.address)) != nil {
                        status = .connected("Connected over Wi-Fi.")
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            status = .paired("Paired, but the phone didn't show up automatically. Enter the IP address & port from the phone's Wireless debugging screen in the “IP Address” tab.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func connectedDevice(guid: String?, host: String) async -> Device? {
        let devices = (try? await Task.detached { try ADBClient.devices() }.value) ?? []
        return devices.first { device in
            device.isReady && device.isWireless &&
                ((guid.map { device.serial.contains($0) } ?? false) || device.serial.hasPrefix(host + ":"))
        }
    }

    private static func host(of address: String) -> String {
        guard let colon = address.lastIndex(of: ":") else { return address }
        return String(address[..<colon])
    }

    private static func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}

struct WirelessConnectView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case qr = "QR Code"
        case code = "Pairing Code"
        case address = "IP Address"
        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var pairing = WirelessPairing()
    @State private var mode: Mode = .qr
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var connectAddress = ""

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Developer Mode over Wi-Fi").font(.title2.bold())
                Text("Lets this Mac browse the phone wirelessly. Needs Developer options; for no setup, use Browser Link instead.")
                    .foregroundStyle(.secondary)
            }

            Picker("Method", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)

            Group {
                switch mode {
                case .qr: qrPane
                case .code: codePane
                case .address: addressPane
                }
            }
            .frame(maxWidth: .infinity, minHeight: 250)

            statusView.frame(minHeight: 36)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onAppear { pairing.startQR() }
        .onDisappear { pairing.stop() }
        .onChange(of: mode) { _, newMode in
            if newMode == .qr { pairing.startQR() } else { pairing.stop(); pairing.status = .idle }
        }
        .onChange(of: pairing.status) { _, status in
            if case .connected = status {
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    dismiss()
                }
            }
        }
    }

    private var qrPane: some View {
        HStack(alignment: .center, spacing: 24) {
            if let image = QRCode.image(pairing.qrPayload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 210, height: 210)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            }
            VStack(alignment: .leading, spacing: 10) {
                Step(number: 1, text: "On your phone, open **Settings › System › Developer options**.")
                Step(number: 2, text: "Turn on **Wireless debugging**, then tap it to open.")
                Step(number: 3, text: "Tap **Pair device with QR code** and scan this code.")
                Text("Requires Android 11 or later. For older phones, connect once with USB and choose “Switch to Wi-Fi” from the device's right-click menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var codePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Step(number: 1, text: "In **Wireless debugging**, tap **Pair device with pairing code**.")
            Step(number: 2, text: "Enter the IP address & port and the 6-digit code shown on the phone.")
            Form {
                TextField("IP address & port", text: $pairAddress, prompt: Text("192.168.1.20:37123"))
                TextField("Pairing code", text: $pairCode, prompt: Text("123456"))
            }
            .formStyle(.grouped)
            .frame(maxWidth: 420)
            Button("Pair") { pairing.pairManually(address: pairAddress, code: pairCode) }
                .keyboardShortcut(.defaultAction)
                .disabled(pairAddress.isEmpty || pairCode.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addressPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to a phone you've already paired, or one switched to Wi-Fi over USB. Use the **IP address & port** shown at the top of the phone's Wireless debugging screen, or `phone-ip:5555`.")
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("IP address & port", text: $connectAddress, prompt: Text("192.168.1.20:41234"))
            }
            .formStyle(.grouped)
            .frame(maxWidth: 420)
            Button("Connect") { pairing.connectManually(address: connectAddress) }
                .keyboardShortcut(.defaultAction)
                .disabled(connectAddress.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusView: some View {
        switch pairing.status {
        case .idle:
            EmptyView()
        case .waitingForScan:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your phone to scan the code…").foregroundStyle(.secondary)
            }
        case .pairing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Pairing…") }
        case .connecting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting…") }
        case .connected(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .paired(let message):
            Label(message, systemImage: "checkmark.circle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if mode == .qr {
                    Button("Try Again") { pairing.startQR() }
                }
            }
        }
    }

}

private struct Step: View {
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
