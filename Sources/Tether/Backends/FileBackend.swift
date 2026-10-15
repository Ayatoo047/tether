import Foundation

/// A way of reaching a phone's files. Implementations block, so call them off the main thread.
protocol FileBackend: AnyObject, Sendable {
    /// Stable identifier used for cache keys.
    var cacheKey: String { get }
    /// Where browsing starts.
    var rootPath: String { get }

    func list(_ path: String) throws -> [RemoteFile]
    /// Recursive listing; parents come before their children.
    func walk(_ root: String) throws -> [(relative: String, file: RemoteFile)]
    func download(_ file: RemoteFile, to url: URL, progress: TransferProgress) throws
    func upload(_ local: URL, to remotePath: String, modified: Date, progress: TransferProgress) throws
    func exists(_ path: String) throws -> Bool
    /// Creates each directory (and any missing parents).
    func makeDirectories(_ paths: [String]) throws
    func rename(_ file: RemoteFile, to newName: String) throws
    func delete(_ files: [RemoteFile]) throws
    func freeSpace(at path: String) -> Int64?
    func breadcrumbs(for path: String) -> [(title: String, path: String)]
    func loadLocations() throws -> [StorageLocation]
}

extension FileBackend {
    func walk(_ root: String) throws -> [(relative: String, file: RemoteFile)] {
        var result: [(relative: String, file: RemoteFile)] = []
        var stack: [(path: String, relative: String)] = [(root, "")]
        while let (directory, relative) = stack.popLast() {
            for file in try list(directory) {
                let childRelative = relative.isEmpty ? file.name : relative + "/" + file.name
                result.append((childRelative, file))
                if file.isDirectory && !file.isSymlink {
                    stack.append((file.path, childRelative))
                }
            }
        }
        return result
    }

    /// Returns `name`, or "name (1).ext" etc. if something already exists at that path.
    func availableName(_ name: String, in directory: String) throws -> String {
        guard try exists(RemotePath.join(directory, name)) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if try !exists(RemotePath.join(directory, candidate)) { return candidate }
            index += 1
        }
    }

    func breadcrumbs(for path: String) -> [(title: String, path: String)] {
        var result = [(title: "Phone", path: "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append((String(component), current))
        }
        return result
    }
}
