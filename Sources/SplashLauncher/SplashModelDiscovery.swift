import Foundation

struct SplashModelDiscovery {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Splash/models", isDirectory: true)
    }

    /// Maps local model IDs (local/<family>) to their original source directory path.
    /// Used by SplashServeArguments to pass --model-dir for assembled local models.
    static var resolvedDirectories: [String: String] = [:]

    /// Maps local model IDs to their draft model directory path.
    /// Used by SplashServeArguments to pass --draft-model.
    static var resolvedDraftDirectories: [String: String] = [:]

    /// Splash registers packages and 1.1 assemblies as owner/repository[:variant] links.
    static func installedModels(in root: URL = directory) -> [String] {
        var models: Set<String> = []
        resolvedDirectories = [:]
        resolvedDraftDirectories = [:]

        let files = FileManager.default
        // Include hidden dirs (.selections, .resolved)
        let allEntries = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []

        // 1. Scan .selections (hash symlinks → model.json → model IDs)
        for entry in allEntries {
            guard entry.lastPathComponent == ".selections" else { continue }
            let selections = (try? files.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil,
                                                             options: .skipsHiddenFiles)) ?? []
            for selection in selections {
                guard let resolvedURL = try? selection.resolvingSymlinksInPath() else { continue }
                let modelJSON = resolvedURL.appendingPathComponent("model.json")
                guard let data = try? String(contentsOf: modelJSON, encoding: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data.data(using: .utf8)!, options: []),
                      let dict = json as? [String: Any] else { continue }

                let modelValue = dict["model"] as? String ?? ""
                let family = dict["family"] as? String ?? ""

                if modelValue.hasPrefix("/") {
                    // Path-based model: use local/<family> format, point --model-dir to original source
                    let localID = "local/\(family.isEmpty ? "model" : family)"
                    models.insert(localID)
                    resolvedDirectories[localID] = modelValue
                    let draftPath = resolvedURL.appendingPathComponent("draft").path
                    if FileManager.default.fileExists(atPath: draftPath) {
                        resolvedDraftDirectories[localID] = draftPath
                    }
                } else if isValidModel(modelID: modelValue) {
                    // owner/repo format: use directly
                    models.insert(modelValue)
                }
            }
        }

        // 2. Scan .resolved for unselected models
        for entry in allEntries {
            guard entry.lastPathComponent == ".resolved" else { continue }
            let resolved = (try? files.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil,
                                                           options: .skipsHiddenFiles)) ?? []
            for resolvedDir in resolved {
                let modelJSON = resolvedDir.appendingPathComponent("model.json")
                guard let data = try? String(contentsOf: modelJSON, encoding: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data.data(using: .utf8)!, options: []),
                      let dict = json as? [String: Any] else { continue }

                let modelValue = dict["model"] as? String ?? ""
                let family = dict["family"] as? String ?? ""

                // Only create local/<family> entries for path-based models.
                // Owner/repo models are already discovered via .selections or owner/repo dirs.
                guard modelValue.hasPrefix("/") else { continue }

                let localID = "local/\(family.isEmpty ? resolvedDir.lastPathComponent : family)"

                // Skip if already discovered via .selections
                guard !models.contains(localID) else { continue }
                models.insert(localID)
                resolvedDirectories[localID] = modelValue
                let draftPath = resolvedDir.appendingPathComponent("draft").path
                if FileManager.default.fileExists(atPath: draftPath) {
                    resolvedDraftDirectories[localID] = draftPath
                }
            }
        }

        // 3. Scan traditional owner/repo directories
        for owner in allEntries {
            guard !owner.lastPathComponent.hasPrefix(".") else { continue }
            let repos = (try? files.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil,
                                                       options: .skipsHiddenFiles)) ?? []
            for repo in repos {
                guard [ "manifest.json", "model.json" ].contains(where: {
                    files.fileExists(atPath: repo.appendingPathComponent($0).path)
                }) else { continue }
                let id = "\(owner.lastPathComponent)/\(repo.lastPathComponent)"
                if isValidModel(modelID: id) {
                    models.insert(id)
                }
            }
        }

        return models.sorted()
    }

    private static func isValidModel(modelID: String) -> Bool {
        var configuration = SplashConfiguration()
        configuration.model = modelID
        return configuration.validationError == nil
    }
}
