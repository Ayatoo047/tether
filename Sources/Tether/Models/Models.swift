import Foundation
import UniformTypeIdentifiers

struct Device: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// USB "File transfer" mode: nothing to enable on the phone.
        case mtp
        /// USB/Wireless debugging: needs Developer options.
        case adb
    }

    let kind: Kind
    /// adb serial, or the USB location for MTP devices.
    let serial: String
    let state: String
    let model: String?

    var id: String { "\(kind.rawValue):\(serial)" }
    var isReady: Bool { state == "device" }
    var isWireless: Bool { kind == .adb && (serial.contains(":") || serial.contains("._adb-tls-connect")) }

    var displayName: String {
        if let model, !model.isEmpty { return model }
        return "Android phone"
    }

    var statusText: String {
        switch (kind, state) {
        case (.mtp, "device"): return "USB · File transfer"
        case (.mtp, _): return "In use by another app"
        case (.adb, "device"): return isWireless ? "Wi-Fi · Developer mode" : "USB · Developer mode"
        case (.adb, "unauthorized"): return "Waiting for you to allow access"
        case (.adb, "offline"): return "Offline"
        case (.adb, "authorizing"), (.adb, "connecting"): return "Connecting…"
        default: return state.capitalized
        }
    }
}

struct RemoteFile: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let mode: UInt32
    var size: Int64
    let modified: Date
    var isDirectory: Bool
    let isSymlink: Bool

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }
    var fileExtension: String { (name as NSString).pathExtension }

    init(directory: String, name: String, mode: UInt32, size: Int64, mtime: Int64) {
        self.name = name
        self.path = RemotePath.join(directory, name)
        self.mode = mode
        self.size = size
        self.modified = Date(timeIntervalSince1970: TimeInterval(mtime))
        let type = mode & 0o170000
        self.isDirectory = type == 0o040000
        self.isSymlink = type == 0o120000
    }

    var kind: String {
        if isDirectory { return "Folder" }
        let ext = fileExtension
        guard !ext.isEmpty else { return "Document" }
        if let type = UTType(filenameExtension: ext), !type.isDynamic, let description = type.localizedDescription {
            return description
        }
        return "\(ext.uppercased()) file"
    }
}

struct StorageLocation: Identifiable, Hashable {
    let name: String
    let path: String
    let systemImage: String
    var id: String { path }

    static func standard(root: String, rootName: String) -> [StorageLocation] {
        [
            .init(name: rootName, path: root, systemImage: "internaldrive"),
            .init(name: "Downloads", path: root + "/Download", systemImage: "arrow.down.circle"),
            .init(name: "Camera", path: root + "/DCIM", systemImage: "camera"),
            .init(name: "Pictures", path: root + "/Pictures", systemImage: "photo"),
            .init(name: "Documents", path: root + "/Documents", systemImage: "doc"),
            .init(name: "Music", path: root + "/Music", systemImage: "music.note"),
            .init(name: "Movies", path: root + "/Movies", systemImage: "film"),
        ]
    }
}

enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// Quotes a string for the device's POSIX shell.
    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum AppPaths {
    static let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Tether", isDirectory: true)
    static let previews = tempRoot.appendingPathComponent("Previews", isDirectory: true)
    static let drags = tempRoot.appendingPathComponent("Drag", isDirectory: true)

    static func isInsideTempRoot(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(tempRoot.resolvingSymlinksInPath().path)
    }
}

enum AppSettings {
    static let downloadFolderKey = "downloadFolder"

    static var downloadFolder: URL {
        if let path = UserDefaults.standard.string(forKey: downloadFolderKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}

func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}
