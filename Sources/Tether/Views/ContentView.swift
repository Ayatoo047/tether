import SwiftUI

enum SidebarItem: Hashable {
    case device(String)
    case location(deviceID: String, path: String)
    case webLink

    var deviceID: String? {
        switch self {
        case .device(let id), .location(let id, _): return id
        case .webLink: return nil
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .task { store.start() }
        .onChange(of: store.devices) { _, devices in
            if selection == nil || (selection != .webLink && store.device(selection?.deviceID) == nil) {
                let preferred = devices.first(where: \.isReady) ?? devices.first
                selection = preferred.map { .device($0.id) }
            }
        }
        .onChange(of: selection) { _, newValue in
            if case .location(let id, let path) = newValue, let device = store.device(id) {
                store.browser(for: device)?.navigate(path)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selection == .webLink {
            WebLinkView()
        } else if let device = store.device(selection?.deviceID) {
            if device.isReady, let browser = store.browser(for: device) {
                FileBrowserView(device: device, model: browser)
                    .id(device.id)
            } else {
                DeviceStateView(device: device)
            }
        } else {
            WelcomeView(openWebLink: { selection = .webLink })
        }
    }
}
