import Foundation

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var adbStatus: String?
    @Published private(set) var locations: [String: [StorageLocation]] = [:]

    private var browsers: [String: BrowserModel] = [:]
    private var adbBackends: [String: ADBBackend] = [:]
    private var loadingLocations = Set<String>()
    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var adbReady = false
            while !Task.isCancelled {
                // USB "File transfer" phones (no setup needed on the phone).
                let mtpDevices = await Task.detached { MTPMonitor.shared.poll() }.value

                // Phones with Developer mode (USB or Wireless debugging), if adb is available.
                var adbDevices: [Device] = []
                if ADBTool.executableURL != nil {
                    if !adbReady {
                        do {
                            try await ADBServer.ensureRunning()
                            adbReady = true
                            self?.adbStatus = nil
                        } catch {
                            self?.adbStatus = error.localizedDescription
                        }
                    }
                    if adbReady {
                        do {
                            adbDevices = try await Task.detached { try ADBClient.devices() }.value
                        } catch {
                            adbReady = false
                        }
                    }
                } else {
                    self?.adbStatus = TetherError.adbNotFound.localizedDescription
                }

                self?.apply(mtpDevices + adbDevices)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    func refreshNow() async {
        let mtp = await Task.detached { MTPMonitor.shared.poll() }.value
        let adb = (try? await Task.detached(operation: { try ADBClient.devices() }).value) ?? []
        apply(mtp + adb)
    }

    private func apply(_ list: [Device]) {
        if list != devices { devices = list }
        let ids = Set(list.map(\.id))
        browsers = browsers.filter { ids.contains($0.key) }
        locations = locations.filter { ids.contains($0.key) }
        for device in list where device.isReady && (locations[device.id]?.isEmpty ?? true) {
            loadLocations(for: device)
        }
    }

    func device(_ id: String?) -> Device? {
        devices.first { $0.id == id }
    }

    func backend(for device: Device) -> FileBackend? {
        switch device.kind {
        case .mtp:
            return MTPMonitor.shared.backend(key: device.serial)
        case .adb:
            if let existing = adbBackends[device.serial] { return existing }
            let backend = ADBBackend(serial: device.serial)
            adbBackends[device.serial] = backend
            return backend
        }
    }

    func browser(for device: Device) -> BrowserModel? {
        if let existing = browsers[device.id] { return existing }
        guard let backend = backend(for: device) else { return nil }
        let browser = BrowserModel(backend: backend)
        browsers[device.id] = browser
        return browser
    }

    func locations(for id: String) -> [StorageLocation] {
        locations[id] ?? []
    }

    private func loadLocations(for device: Device) {
        guard !loadingLocations.contains(device.id), let backend = backend(for: device) else { return }
        loadingLocations.insert(device.id)
        let id = device.id
        Task {
            let result = (try? await Task.detached { try backend.loadLocations() }.value) ?? []
            loadingLocations.remove(id)
            if self.device(id) != nil { locations[id] = result }
        }
    }

    // MARK: Developer-mode connection management

    /// Switches a USB debugging connection to classic TCP/IP mode on port 5555 and connects to it.
    func switchToWiFi(_ device: Device) async throws -> String {
        let serial = device.serial
        let output = try await Task.detached {
            try ADBClient.shell(serial: serial, "ip -f inet addr show wlan0 2>/dev/null; ip route get 1.1.1.1 2>/dev/null")
        }.value
        guard let ip = firstCapture(#"inet (\d+\.\d+\.\d+\.\d+)"#, in: output)
                ?? firstCapture(#"src (\d+\.\d+\.\d+\.\d+)"#, in: output) else {
            throw TetherError.remote("Couldn't find the phone's Wi-Fi address. Make sure Wi-Fi is on and connected to the same network as this Mac.")
        }
        try await ADBTool.tcpip(serial: serial)
        try await Task.sleep(for: .seconds(2))
        let address = "\(ip):5555"
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try await ADBTool.connect(address)
                await refreshNow()
                return address
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError ?? TetherError.remote("Could not connect to \(address).")
    }

    func disconnect(_ device: Device) async {
        try? await ADBTool.disconnect(device.serial)
        await refreshNow()
    }
}
