import Foundation

/// Where installed models really live and how much space they use. Splash's models folder
/// holds only links; the files are in the Hugging Face cache, sometimes shared between models.
/// Read-only: the launcher never moves or deletes Splash data.
struct SplashModelStorage: Equatable {
    struct Model: Equatable, Identifiable {
        enum Format: String { case package = "Splash package", gguf = "GGUF", other = "Other" }

        let id: String
        let format: Format
        /// Unique bytes of every file the model uses, including files shared with other models.
        let bytes: Int64
        /// The part of `bytes` that other installed models also use.
        let sharedBytes: Int64
        /// Folders holding the real files, largest share first (e.g. a Hugging Face repo folder).
        let locations: [URL]
        /// Copies Splash converted from this model's files, in the prepared weights cache.
        let preparedBytes: Int64
    }

    let models: [Model]
    /// Splash's cache of weights converted for its engine. Rebuilt on demand if removed.
    let preparedCacheBytes: Int64
    /// Cache entries converted from models that are no longer installed. Splash doesn't
    /// remove these when a model is deleted.
    let orphanedPreparedBytes: Int64
    /// SSD KV cache size (temp, exists only while Splash is running).
    let ssdCacheBytes: Int64
    /// Where the SSD KV cache lives, if present.
    let ssdCachePath: String?
    /// Persistent KV cache size (when --persistent-cache is enabled).
    let persistentCacheBytes: Int64
    /// Where the persistent KV cache lives, if present.
    let persistentCachePath: String?

    static var preparedCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Splash/weights", isDirectory: true)
    }

    static func scan(modelsRoot: URL = SplashModelDiscovery.directory,
                     preparedCache: URL = preparedCacheDirectory) -> SplashModelStorage {
        let ids = SplashModelDiscovery.installedModels(in: modelsRoot)
        
        // Resolve model paths: local models use their source directory, others use modelsRoot
        func modelPath(for id: String) -> URL? {
            if id.hasPrefix("local/") {
                // Local model: use the resolved source directory
                guard let sourcePath = SplashModelDiscovery.resolvedDirectories[id] else { return nil }
                return URL(fileURLWithPath: sourcePath)
            } else if id.hasPrefix("/") {
                return URL(fileURLWithPath: id)
            } else {
                return modelsRoot.appendingPathComponent(id)
            }
        }
        
        let filesByModel = Dictionary(uniqueKeysWithValues: ids.compactMap { id -> (String, [String: RealFile])? in
            guard let path = modelPath(for: id) else { return nil }
            return (id, realFiles(under: path))
        })
        var users: [String: Int] = [:]
        for files in filesByModel.values { for path in files.keys { users[path, default: 0] += 1 } }
        func size(_ files: [String: RealFile]) -> Int64 { files.values.reduce(0) { $0 + $1.bytes } }

        // Each cache entry records the model file it was converted from.
        let modelRoots = ids.compactMap { id -> (String, String)? in
            guard let path = modelPath(for: id) else { return nil }
            return (id, path.resolvingSymlinksInPath().path + "/")
        }
        var preparedByModel: [String: Int64] = [:]
        var orphanedPrepared: Int64 = 0
        for entry in preparedEntries(in: preparedCache) {
            guard let source = entry.source else { continue }
            let realSource = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
            let owner = modelRoots.first { source.hasPrefix($0.1) }?.0
                ?? ids.first { filesByModel[$0]?[realSource] != nil }
            if let owner { preparedByModel[owner, default: 0] += entry.bytes } else { orphanedPrepared += entry.bytes }
        }

        let models = ids.map { id -> Model in
            let files = filesByModel[id] ?? [:]
            var bytesByLocation: [URL: Int64] = [:]
            for (path, file) in files { bytesByLocation[location(of: path), default: 0] += file.bytes }
            let names = Set(files.values.map(\.name))
            let format: Model.Format = names.contains { $0.hasSuffix(".gguf") } ? .gguf
                : names.contains("manifest.json") ? .package : .other
            return Model(
                id: id, format: format,
                bytes: size(files),
                sharedBytes: size(files.filter { (users[$0.key] ?? 0) > 1 }),
                locations: bytesByLocation.sorted { $0.value > $1.value }.map(\.key),
                preparedBytes: preparedByModel[id] ?? 0
            )
        }
        return SplashModelStorage(models: models,
                                  preparedCacheBytes: size(realFiles(under: preparedCache)),
                                  orphanedPreparedBytes: orphanedPrepared,
                                  ssdCacheBytes: ssdCacheSize,
                                  ssdCachePath: ssdCacheDir?.path,
                                  persistentCacheBytes: persistentCacheSize,
                                  persistentCachePath: persistentCacheDir?.path)
    }

    /// Default persistent cache location: ~/Library/Caches/Splash/prefix-cache/
    private static var defaultPersistentCacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Splash/prefix-cache", isDirectory: true)
    }

    private static var persistentCacheSize: Int64 {
        let dir = defaultPersistentCacheDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        return realFiles(under: dir).values.reduce(0) { $0 + $1.bytes }
    }

    private static var persistentCacheDir: URL? {
        let dir = defaultPersistentCacheDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return dir
    }

    /// Scan the user's temp directory for Splash SSD KV cache files.
    /// Splash creates temp files in NSTemporaryDirectory() while running.
    private static var ssdCacheSize: Int64 {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let file as URL in enumerator {
            let name = file.lastPathComponent.lowercased()
            guard name.contains("splash") || name.contains("kv") || name.contains("ssd") else { continue }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static var ssdCacheDir: URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in enumerator {
            let name = file.lastPathComponent.lowercased()
            if name.contains("splash") || name.contains("kv") || name.contains("ssd") {
                return tempDir
            }
        }
        return nil
    }

    struct PreparedEntry: Equatable {
        let bytes: Int64
        /// The model file the entry was converted from, as Splash recorded it.
        let source: String?
    }

    /// Entries of Splash's prepared weights cache. Each folder holds the converted weights and a
    /// `source` file with lines such as `source /path/to/model/target/model.gguf`.
    static func preparedEntries(in cache: URL) -> [PreparedEntry] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return folders.map { folder in
            let record = (try? String(contentsOf: folder.appendingPathComponent("source"), encoding: .utf8)) ?? ""
            let source = record.split(separator: "\n").first { $0.hasPrefix("source ") }
                .map { String($0.dropFirst("source ".count)) }
            return PreparedEntry(bytes: realFiles(under: folder).values.reduce(0) { $0 + $1.bytes }, source: source)
        }
    }

    struct RealFile: Equatable {
        let bytes: Int64
        /// The name the model uses; Hugging Face stores the real file under a hash.
        let name: String
    }

    /// Every regular file reachable from `root`, following links, keyed by its real path.
    static func realFiles(under root: URL) -> [String: RealFile] {
        var files: [String: RealFile] = [:]
        var visitedDirectories = Set<String>()
        func visit(_ url: URL) {
            let real = url.resolvingSymlinksInPath()
            guard let values = try? real.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            else { return }
            if values.isDirectory == true {
                guard visitedDirectories.insert(real.path).inserted else { return }
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: real, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                children.forEach(visit)
            } else if values.isRegularFile == true {
                files[real.path] = RealFile(bytes: Int64(values.fileSize ?? 0), name: url.lastPathComponent)
            }
        }
        visit(root)
        return files
    }

    /// The Hugging Face repo folder (`models--owner--name`) holding a file, else its parent folder.
    static func location(of path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        var candidate = url.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.lastPathComponent.hasPrefix("models--") { return candidate }
            candidate.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }
}
