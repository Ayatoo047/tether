import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: DeviceStore
    @Binding var selection: SidebarItem?
    @State private var showWireless = false
    @State private var actionMessage: String?
    @State private var busyID: String?

    var body: some View {
        List(selection: $selection) {
            Section("Devices") {
                if store.devices.isEmpty {
                    Text("Plug in your phone with a USB cable")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(store.devices) { device in
                    DeviceRow(device: device, isBusy: busyID == device.id)
                        .tag(SidebarItem.device(device.id))
                        .contextMenu { deviceMenu(device) }
                }
            }

            Section("Wireless") {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Browser Link")
                        Text("Wi-Fi · no setup on phone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "qrcode")
                        .foregroundStyle(Color.accentColor)
                }
                .tag(SidebarItem.webLink)
            }

            if let device = store.device(selection?.deviceID), device.isReady {
                let locations = store.locations(for: device.id)
                if !locations.isEmpty {
                    Section("Locations") {
                        ForEach(locations) { location in
                            Label(location.name, systemImage: location.systemImage)
                                .tag(SidebarItem.location(deviceID: device.id, path: location.path))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Menu {
                Button("Pair Over Wi-Fi with Developer Mode…") { showWireless = true }
            } label: {
                Label("Advanced", systemImage: "hammer")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .help("Browse the phone over Wi-Fi using Android's Wireless debugging (needs Developer options)")
        }
        .sheet(isPresented: $showWireless) {
            WirelessConnectView()
        }
        .alert("Tether", isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionMessage ?? "")
        }
    }

    @ViewBuilder
    private func deviceMenu(_ device: Device) -> some View {
        if device.kind == .adb && device.isReady && !device.isWireless {
            Button("Switch to Wi-Fi") {
                busyID = device.id
                Task {
                    do {
                        let address = try await store.switchToWiFi(device)
                        actionMessage = "Connected over Wi-Fi at \(address). You can unplug the cable now."
                    } catch {
                        actionMessage = error.localizedDescription
                    }
                    busyID = nil
                }
            }
        }
        if device.isWireless {
            Button("Disconnect") {
                Task { await store.disconnect(device) }
            }
        }
        if device.kind == .adb {
            Button("Copy Serial Number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.serial, forType: .string)
            }
        }
    }
}

struct DeviceRow: View {
    let device: Device
    var isBusy = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "smartphone")
                .font(.title3)
                .foregroundStyle(device.isReady ? Color.accentColor : Color.secondary)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: device.isWireless ? "wifi" : device.kind == .adb ? "hammer.fill" : "cable.connector")
                        .font(.system(size: 8, weight: .bold))
                        .padding(2)
                        .background(.background, in: Circle())
                        .offset(x: 5, y: 3)
                }
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName).lineLimit(1)
                Text(device.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if isBusy {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
