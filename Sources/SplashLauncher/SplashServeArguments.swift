import Foundation

/// Builds an explicit argument array for Splash. API keys are never arguments.
enum SplashServeArguments {
    static func serveArguments(_ configuration: SplashConfiguration) -> [String] {
        var arguments = [
            "serve",
            "--model", configuration.model,
            "--host", configuration.host,
            "--port", String(configuration.port),
        ]
        for name in configuration.servedModelNames where !name.isEmpty { arguments += ["--served-model-name", name] }
        if !configuration.defaultReasoningEffort.isEmpty {
            arguments += ["--default-reasoning-effort", configuration.defaultReasoningEffort]
        }
        if configuration.kvFormat != "int8" { arguments += ["--kv-format", configuration.kvFormat] }
        if !configuration.maxMemory.isEmpty { arguments += ["--max-memory", configuration.maxMemory] }
        if !configuration.maxContext.isEmpty { arguments += ["--max-context", configuration.maxContext] }
        for host in configuration.allowedHosts where !host.isEmpty { arguments += ["--allowed-host", host] }
        if !configuration.maxRequestSize.isEmpty { arguments += ["--max-request-size", configuration.maxRequestSize] }
        if !configuration.maxImagePixels.isEmpty { arguments += ["--max-image-pixels", configuration.maxImagePixels] }
        if configuration.noWebUI { arguments.append("--no-webui") }
        if !configuration.idleRelease.isEmpty { arguments += ["--idle-release", configuration.idleRelease] }
        if !configuration.maxCacheDisk.isEmpty { arguments += ["--max-cache-disk", configuration.maxCacheDisk] }
        if configuration.persistentCache { arguments.append("--persistent-cache") }
        if !configuration.thinkingTokenBudget.isEmpty { arguments += ["--thinking-token-budget", configuration.thinkingTokenBudget] }
        if !configuration.requestTimeout.isEmpty { arguments += ["--request-timeout", configuration.requestTimeout] }
        for flag in configuration.customFlags where !flag.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = flag.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            arguments.append(contentsOf: parts)
        }
        // Local model flags (Splash 1.5.0+)
        if configuration.model.hasPrefix("local/") {
            // Local model: point to source dir and draft from Splash registry
            if let resolvedPath = SplashModelDiscovery.resolvedDirectories[configuration.model] {
                arguments += ["--model-dir", resolvedPath]
            }
            if !configuration.localDraftModel.isEmpty {
                arguments += ["--draft-model", configuration.localDraftModel]
            } else if let draftPath = SplashModelDiscovery.resolvedDraftDirectories[configuration.model] {
                arguments += ["--draft-model", draftPath]
            }
            if !configuration.localMmproj.isEmpty { arguments += ["--mmproj", configuration.localMmproj] }
        } else if !configuration.localModelDir.isEmpty {
            // User-specified local model path
            if !configuration.localModelDir.isEmpty { arguments += ["--model-dir", configuration.localModelDir] }
            if !configuration.localDraftModel.isEmpty { arguments += ["--draft-model", configuration.localDraftModel] }
            if !configuration.localMmproj.isEmpty { arguments += ["--mmproj", configuration.localMmproj] }
        }
        return arguments
    }
}
