import AppKit
import SwiftUI

/// Model, connection and server options, the installed models list, and the API key.
struct SettingsPage: View {
    @ObservedObject var controller: SplashProcessController
    @State private var installedModels: [String] = []
    @State private var modelStorage: SplashModelStorage?
    @State private var useCustomModel = false
    @State private var keyDraft = ""
    @State private var customFlagsHelp = false
    @State private var customFlagsText: String = ""
    @State private var localModelId: String = ""
    @State private var localModelDir: String = ""
    @State private var localDraftModel: String = ""
    @State private var localMmproj: String = ""
    @State private var preparerState: SplashModelPreparer.State = .idle
    @State private var preparerOutput: String = ""
    @State private var showingPrepareProgress = false
    @State private var isPreparing = false
    @State private var confirmingDelete: SplashModelStorage.Model?
    @State private var showingDeleteConfirm = false

    private var localModelReady: Bool {
        !localModelDir.isEmpty && FileManager.default.fileExists(atPath: localModelDir)
    }

    private struct FlagInfo: Identifiable, Equatable {
        let id = UUID()
        let option: String
        let value: String
    }

    private var unmanagedFlags: [FlagInfo] {
        [
            FlagInfo(option: "--allow-idle-sleep", value: "Allow system sleep"),
            FlagInfo(option: "--allowed-host", value: "Extra HTTP Host names (repeatable)"),
            FlagInfo(option: "--allowed-origin", value: "Browser origins (repeatable)"),
            FlagInfo(option: "--announce-served-name", value: "Report alias in responses"),
            FlagInfo(option: "--cache-dir", value: "Persistent cache path"),
            FlagInfo(option: "--decode-share", value: "Decode time ratio"),
            FlagInfo(option: "--disable-ane", value: "GPU-only prefill"),
            FlagInfo(option: "--draft-model", value: "Alternative DFlash2 draft"),
            FlagInfo(option: "--expert-memory", value: "Expert cache size"),
            FlagInfo(option: "--language-only", value: "Skip vision"),
            FlagInfo(option: "--max-cache-disk-writes", value: "Daily write budget"),
            FlagInfo(option: "--max-image-pixels", value: "Max pixels after resize (e.g. 4194304)"),
            FlagInfo(option: "--max-request-size", value: "Largest HTTP request body (e.g. 128MB)"),
            FlagInfo(option: "--model-dir", value: "Local GGUF/MLX directory"),
            FlagInfo(option: "--mmproj", value: "Vision projector GGUF"),
            FlagInfo(option: "--offline", value: "No Hub check"),
            FlagInfo(option: "--ple-memory", value: "PLE table memory"),
            FlagInfo(option: "--queue-size", value: "Concurrent request limit"),
            FlagInfo(option: "--revision", value: "Branch, tag, or commit"),
            FlagInfo(option: "--sparse-kv-memory", value: "SSD KV block memory"),
            FlagInfo(option: "--state-format", value: "fp32 | bf16"),
            FlagInfo(option: "--thinking-end-text", value: "End-of-thinking marker"),
            FlagInfo(option: "--verify-rows", value: "auto | all"),
        ]
    }

    private var aliases: Binding<String> {
        Binding(
            get: { controller.configuration.servedModelNames.joined(separator: ", ") },
            set: { controller.configuration.servedModelNames = splitList($0) }
        )
    }
    private var allowedHosts: Binding<String> {
        Binding(
            get: { controller.configuration.allowedHosts.joined(separator: ", ") },
            set: { controller.configuration.allowedHosts = splitList($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MissingSplashNotice(controller: controller)
            if controller.state.isRunning {
                Notice("Stop Splash to edit server settings. Changes apply on the next start.", symbol: "lock")
            }
            Panel("Model & connection", symbol: "cpu") {
                HStack {
                    SettingLabel("Executable", helpText: "The installed splash-m1 program this launcher starts. Choose a different executable if automatic discovery found the wrong one.")
                    Text(controller.executable?.path ?? "Not found")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { chooseSplashExecutable(for: controller) }
                        .disabled(controller.state.isRunning)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SettingLabel("Model", defaultValue: "incoai/Qwen3.8-27B-Splash",
                                     helpText: "Choose an installed Splash model, or select Other model to enter a Hugging Face owner/repository ID, optionally followed by :VARIANT for GGUF models in Splash 1.1 or newer. Stop the server before changing models.")
                        Picker("Model", selection: Binding(
                            get: { useCustomModel || !installedModels.contains(controller.configuration.model) ? "__custom__" : controller.configuration.model },
                            set: { value in
                                useCustomModel = value == "__custom__"
                                if !useCustomModel { controller.configuration.model = value }
                            }
                        )) {
                            ForEach(installedModels, id: \.self) { Text($0).tag($0) }
                            Text("Other model…").tag("__custom__")
                        }
                        .labelsHidden().frame(width: 300)
                        .accessibilityLabel("Installed model")
                        .disabled(controller.state.isRunning)
                    }
                    if useCustomModel || !installedModels.contains(controller.configuration.model) {
                        field("Model ID", text: $controller.configuration.model,
                                     prompt: "owner/repository", defaultValue: "incoai/Qwen3.8-27B-Splash",
                                     helpText: "Enter a supported model ID, such as incoai/Qwen3.8-27B-Splash. Splash 1.1 or newer also accepts GGUF variants such as unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M. Splash may download it the next time you start the server.")
                    }
                    HStack {
                        Text(installedModels.isEmpty ? "No installed models found." : "\(String(installedModels.count)) installed models")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { refreshModels() }
                    }
                    installedModelsList
                }
                .onAppear { refreshModels() }
                field("Host", text: $controller.configuration.host,
                             prompt: "127.0.0.1", defaultValue: "127.0.0.1",
                             helpText: "The network address Splash listens on. 127.0.0.1 allows connections from this Mac only; 0.0.0.0 listens on all IPv4 interfaces.")
                HStack {
                    SettingLabel("Port", defaultValue: "8000",
                                 helpText: "The network port for Splash's API and browser chat page. Use a port that is not already in use.")
                    TextField("", value: $controller.configuration.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .accessibilityLabel("Port")
                        .disabled(controller.state.isRunning)
                }
            }

            Panel("Local Model Preparation", symbol: "folder.badge.plus") {
                if controller.state.isRunning {
                    Notice("Stop Splash to prepare a local model. Changes apply on the next start.", symbol: "lock")
                }
                
                // Model ID
                SettingLabel("Model ID",
                             helpText: "A short name for this model as it appears in the launcher and API. Default is extracted from the file name.")
                TextField("e.g. local/mymodel", text: $localModelId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLocked)
                
                // Local model
                SettingLabel("Local model",
                             helpText: "A GGUF file (.gguf) or a model folder containing the model weights.")
                HStack(spacing: 8) {
                    Button("Choose…") { chooseLocalModel() }
                        .disabled(isLocked)
                    if localModelDir.isEmpty {
                        Text("No model selected")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        let info = localModelInfo()
                        Text("\(info.name)  (\(info.size))")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(info.path)
                    }
                }
                
                // Draft model
                SettingLabel("Draft model",
                             helpText: "Leave blank for Splash to download the supported/compatible draft model.")
                HStack(spacing: 8) {
                    Button("Choose…") { chooseDraftModel() }
                        .disabled(isLocked)
                    if localDraftModel.isEmpty {
                        Text("Auto (Splash will download a compatible draft)")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(localDraftModel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(localDraftModel)
                    }
                }
                
                // Vision projector
                SettingLabel("Vision projector (mmproj)",
                             helpText: "Optional: a GGUF vision projector file for multimodal support. Only needed for GGUF models.")
                HStack(spacing: 8) {
                    Button("Choose…") { chooseMmproj() }
                        .disabled(isLocked)
                    if localMmproj.isEmpty {
                        Text("None")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(localMmproj)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(localMmproj)
                    }
                }
                if !preparerState.isFinal {
                    if case .preparing(let progress) = preparerState {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ProgressView(value: progress)
                                    .frame(width: 200)
                                Text("\(Int(progress * 100))%")
                                    .font(.callout).monospacedDigit()
                            }
                            Text("Preparing model… Splash will download and prepare the weights.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Stop") {
                                isPreparing = false
                                preparerState = .idle
                                preparerOutput = ""
                            }
                        }
                    }
                } else if preparerState.isFinal {
                    switch preparerState {
                    case .ready(let modelId):
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Model \(modelId) is ready.").font(.callout.weight(.medium))
                            }
                            Text("The model has been prepared and can now be selected and started.")
                                .font(.caption).foregroundStyle(.secondary)
                            if !preparerOutput.isEmpty {
                                Text(preparerOutput.prefix(200) + (preparerOutput.count > 200 ? "…" : ""))
                                    .font(.caption).monospaced().foregroundStyle(.tertiary)
                            }
                            HStack {
                                Button("Save & add to models list") {
                                    controller.configuration.localModelId = modelId
                                    controller.configuration.localModelDir = localModelDir
                                    controller.configuration.localDraftModel = localDraftModel
                                    controller.configuration.localMmproj = localMmproj
                                    controller.configuration.model = modelId
                                    refreshModels()
                                    preparerState = .idle
                                    preparerOutput = ""
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Start Splash with this model") {
                                    controller.configuration.localModelId = modelId
                                    controller.configuration.localModelDir = localModelDir
                                    controller.configuration.localDraftModel = localDraftModel
                                    controller.configuration.localMmproj = localMmproj
                                    preparerState = .idle
                                    preparerOutput = ""
                                    controller.start()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(SplashTheme.accent)
                                Button("Discard") {
                                    preparerState = .idle
                                    preparerOutput = ""
                                }
                                .buttonStyle(.link)
                            }
                        }
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text("Preparation failed").font(.callout.weight(.medium))
                            }
                            Text(message).font(.caption).foregroundStyle(.red)
                            Button("Try again") {
                                preparerState = .idle
                                preparerOutput = ""
                            }
                                .buttonStyle(.link)
                        }
                    default:
                        EmptyView()
                    }
                } else {
                    Button("Prepare model") {
                        prepareLocalModel()
                    }
                    .disabled(!localModelReady || isLocked || isPreparing)
                }
            }

            Panel("Model cache", symbol: "internaldrive") {
                cachePanel
            }

            Panel("Server settings", symbol: "slider.horizontal.3") {
                field("Model aliases", text: aliases,
                             prompt: "Comma-separated names", defaultValue: "None",
                             helpText: "Extra names that API clients can use for the loaded model. Separate names with commas. This does not load additional models.")
                HStack {
                    SettingLabel("Reasoning effort", helpText: "The default thinking level when a request does not specify one. Model default leaves the choice to the model. Higher levels may take longer and use more tokens.")
                    Picker("", selection: $controller.configuration.defaultReasoningEffort) {
                        Text("Model default").tag("")
                        ForEach(controller.configuration.reasoningEfforts, id: \.self) { Text(controller.configuration.reasoningLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .accessibilityLabel("Reasoning effort")
                    .disabled(controller.state.isRunning)
                }
                if let guide = controller.configuration.reasoningGuide {
                    Text(guide + " Chat apps can override this default with their own reasoning setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    SettingLabel("KV cache format", helpText: "Precision of the context cache. int8 uses less memory; bf16 uses more memory for higher precision.")
                    Picker("", selection: $controller.configuration.kvFormat) {
                        Text("int8 (default)").tag("int8")
                        Text("bf16").tag("bf16")
                    }
                    .labelsHidden()
                    .frame(width: 230)
                    .accessibilityLabel("KV cache format")
                    .disabled(controller.state.isRunning)
                }
                field("Maximum memory", text: $controller.configuration.maxMemory,
                             prompt: "e.g. 28GB", defaultValue: "Automatic when blank",
                             helpText: "Caps the memory Splash may use for Metal. Leave blank to let Splash choose. Splash treats GB as 1,024 cubed bytes.")
                field("Maximum context (tokens)", text: $controller.configuration.maxContext,
                             prompt: "e.g. 128K", defaultValue: "Automatic when blank",
                             helpText: "Limits the number of tokens in one request's context. 128K means 131,072 tokens. Blank lets Splash choose within the memory budget.")
                field("Idle release", text: $controller.configuration.idleRelease,
                             prompt: "e.g. 2m", defaultValue: "Automatic when blank",
                             helpText: "How long Splash stays loaded after the last request before releasing the model. e.g. 2m, 30s, 1h.")
                field("Max cache disk", text: $controller.configuration.maxCacheDisk,
                             prompt: "e.g. 16G", defaultValue: "Auto (up to 32 GiB); 0 turns it off",
                             helpText: "Maximum disk space for Splash's SSD/KV cache. e.g. 16G, 32G. Set 0 to disable disk caching.")
                HStack {
                    SettingLabel("Persistent cache", defaultValue: "Off",
                                 helpText: "Keep the KV cache on disk across Splash restarts instead of clearing it on exit.")
                    Toggle("", isOn: $controller.configuration.persistentCache)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Persistent cache")
                        .disabled(controller.state.isRunning)
                }
                field("Thinking token budget", text: $controller.configuration.thinkingTokenBudget,
                             prompt: "e.g. 4096", defaultValue: "Model default when blank",
                             helpText: "Maximum tokens the model may spend on thinking/reasoning per request.")
                field("Request timeout", text: $controller.configuration.requestTimeout,
                             prompt: "e.g. 120s", defaultValue: "Automatic when blank",
                             helpText: "Maximum time to wait for a request to complete before timing out. e.g. 120s, 5m.")
                HStack {
                    SettingLabel("Disable web UI", defaultValue: "Web UI enabled",
                                 helpText: "Hides Splash's built-in browser chat page. The API remains available.")
                    Toggle("", isOn: $controller.configuration.noWebUI)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("Disable web UI")
                        .disabled(controller.state.isRunning)
                }
            }

            Panel("Additional/Custom Flags", symbol: "wrench.and.screwdriver") {
                if controller.state.isRunning {
                    Notice("Stop Splash to edit custom flags. Changes apply on the next start.", symbol: "lock")
                }
                SettingLabel("Additional arguments",
                             helpText: "Extra arguments passed directly to Splash on startup. Enter each flag and its value on its own line (e.g. \"--idle-release off\"). Tap a flag below to add it here. Only flags that the launcher does not already manage are listed below; use those instead when possible.")
                TextEditor(text: $customFlagsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 50, maxHeight: 120)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLocked)
                    .accessibilityLabel("Additional server flags")
                    .onChange(of: customFlagsText) {
                        controller.configuration.customFlags = customFlagsText.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .onAppear {
                        customFlagsText = controller.configuration.customFlags.joined(separator: "\n")
                    }
                    .submitLabel(.done)
                Button("Show all available flags") { customFlagsHelp.toggle() }
                    .buttonStyle(.link)
                    .help("View the complete list of Splash serve options.")
                .popover(isPresented: $customFlagsHelp, arrowEdge: .trailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tap a flag to add it to your custom arguments:")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(unmanagedFlags, id: \.option) { f in
                                Button {
                                    let insertion = "\n\(f.option)"
                                    // Insert at cursor or end
                                    var text = customFlagsText
                                    if text.hasSuffix("\n") || text.isEmpty {
                                        text = text + insertion
                                    } else {
                                        text = text + "\n" + insertion
                                    }
                                    customFlagsText = text
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(f.option).font(.callout.monospaced())
                                        Text(f.value).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(6)
                                    .background(SplashTheme.inset, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .buttonBorderShape(.roundedRectangle)
                            }
                        }
                        .padding(12)
                        .frame(width: 480, alignment: .leading)
                    }
                }
            }

            Panel("API access", symbol: "lock.shield") {
                Text(controller.hasAPIKey ? "Saved in Keychain" : "No API key saved")
                    .foregroundStyle(.secondary)
                HStack {
                    SettingLabel("New API key", helpText: "Optional key saved in macOS Keychain. API clients must send it as a Bearer token. The saved key is never shown here.")
                    SecureField("", text: $keyDraft, prompt: Text("Enter a key"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 230)
                        .accessibilityLabel("New API key")
                        .disabled(controller.state.isRunning)
                        .onSubmit(saveKey)
                }
                HStack {
                    Button("Save key", action: saveKey)
                        .disabled(keyDraft.isEmpty || controller.state.isRunning)
                    Button("Remove key") { controller.removeAPIKey() }
                        .disabled(!controller.hasAPIKey || controller.state.isRunning)
                }
                // Splash reads the key only when it starts, so changes wait until it's stopped.
                if controller.state.isRunning {
                    Notice("Stop Splash to change the API key. The key is applied when Splash starts.", symbol: "lock")
                }
                if let error = controller.keyErrorMessage { Text(error).foregroundStyle(.red) }
            }
        }
    }

    private func refreshModels() {
        installedModels = SplashModelDiscovery.installedModels()
        Task {
            let storage = await Task.detached(priority: .utility) { SplashModelStorage.scan() }.value
            modelStorage = storage
        }
        refreshCacheSizes()
    }

    // MARK: - Model Cache

    @ViewBuilder
    private var cachePanel: some View {
        Group {
            SettingLabel("Models and Cache (SSD, persistent) size", helpText: "Installed models, their on-disk footprint, and SSD KV cache usage.")
            
            if modelStorage?.models.isEmpty == true {
                Text("No models found.").foregroundStyle(.secondary)
            } else {
                ForEach(modelStorage?.models ?? []) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.id)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entry.locations.first?.path ?? "—")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Delete", role: .destructive) {
                            confirmingDelete = entry
                            showingDeleteConfirm = true
                        }
                        .font(.caption)
                        .disabled(isLocked)
                    }
                    .padding(.vertical, 2)
                }
            }
            
            // SSD KV cache
            if let ssdPath = modelStorage?.ssdCachePath, modelStorage?.ssdCacheBytes ?? 0 > 0 {
                HStack {
                    VStack(alignment: .leading) {
                        Text("SSD KV cache")
                            .lineLimit(1)
                        Text(ssdPath)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: modelStorage!.ssdCacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .padding(.top, 8)
            }
            
            // Persistent KV cache
            if let persistPath = modelStorage?.persistentCachePath, modelStorage?.persistentCacheBytes ?? 0 > 0 {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Persistent KV cache")
                            .lineLimit(1)
                        Text(persistPath)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: modelStorage!.persistentCacheBytes, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .padding(.top, 4)
            }
        }
        .confirmationDialog(
            confirmingDelete.map { "Delete \($0.id)?" } ?? "Delete model?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = confirmingDelete {
                    deleteModel(entry)
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                confirmingDelete = nil
            }
        } message: {
            Text("This will remove the model and its source files. This action cannot be undone.")
        }
    }
    
    private func refreshCacheSizes() {
        // modelStorage is already populated by refreshModels()
    }
    
    private func deleteModel(_ entry: SplashModelStorage.Model) {
        Task {
            let fm = FileManager.default
            let modelsRoot = SplashModelDiscovery.directory
            
            if entry.id.hasPrefix("local/") {
                // Local model: remove .selections symlink, .resolved dir, and source files
                let selectionsDir = modelsRoot.appendingPathComponent(".selections")
                let selections = (try? fm.contentsOfDirectory(at: selectionsDir, includingPropertiesForKeys: nil)) ?? []
                for selection in selections {
                    let resolved = (try? selection.resolvingSymlinksInPath()) ?? selection
                    let modelJSON = resolved.appendingPathComponent("model.json")
                    if let data = try? String(contentsOf: modelJSON, encoding: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data.data(using: .utf8)!, options: []),
                       let dict = json as? [String: Any],
                       let family = dict["family"] as? String,
                       "local/\(family)" == entry.id {
                        // Remove the selection symlink
                        try? fm.removeItem(at: selection)
                        // Remove the resolved directory
                        try? fm.removeItem(at: resolved)
                        // Remove the source files
                        if let sourcePath = SplashModelDiscovery.resolvedDirectories[entry.id] {
                            try? fm.removeItem(atPath: sourcePath)
                        }
                        break
                    }
                }
            } else {
                // Owner/repo model: remove from models directory
                let modelPath = modelsRoot.appendingPathComponent(entry.id)
                try? fm.removeItem(at: modelPath)
            }
            
            // Refresh the model list
            refreshModels()
        }
    }

    /// Each installed model's real size and location. Splash's models folder holds only links,
    /// so "Show files" opens the folder that actually contains the model's files.
    @ViewBuilder
    private var installedModelsList: some View {
        if let storage = modelStorage, !storage.models.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(storage.models) { model in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.id).font(.callout).textSelection(.enabled)
                            Text(modelDetail(model)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(formattedFileSize(model.bytes + model.preparedBytes)).font(.callout.weight(.medium)).monospacedDigit()
                        Button("Show files") { revealInFinder(model.locations.first) }
                            .disabled(model.locations.isEmpty)
                            .help(model.locations.map(\.path).joined(separator: "\n"))
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prepared weights cache").font(.callout)
                        Text(preparedCacheDetail(storage)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(formattedFileSize(storage.preparedCacheBytes)).font(.callout.weight(.medium)).monospacedDigit()
                    Button("Show files") { revealInFinder(SplashModelStorage.preparedCacheDirectory) }
                        .disabled(storage.preparedCacheBytes == 0)
                }
                .padding(.vertical, 9)
            }
            .padding(.horizontal, 14)
            .background(SplashTheme.inset, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func modelDetail(_ model: SplashModelStorage.Model) -> String {
        var parts = [model.format.rawValue]
        if model.preparedBytes > 0 {
            parts.append("\(formattedFileSize(model.bytes)) download + \(formattedFileSize(model.preparedBytes)) prepared")
        }
        if model.sharedBytes > 0 { parts.append("\(formattedFileSize(model.sharedBytes)) shared with other models") }
        if model.locations.count > 1 { parts.append("files in \(model.locations.count) folders") }
        return parts.joined(separator: " · ")
    }

    private func preparedCacheDetail(_ storage: SplashModelStorage) -> String {
        let summary = "Weights Splash converted for its engine. Rebuilt automatically if removed."
        guard storage.orphanedPreparedBytes > 0 else { return summary }
        return "\(formattedFileSize(storage.orphanedPreparedBytes)) is from models that are no longer installed. "
            + "Splash doesn't remove it when a model is deleted; it's safe to delete. " + summary
    }

    private func formattedFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func revealInFinder(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func saveKey() {
        guard !keyDraft.isEmpty, !controller.state.isRunning else { return }
        controller.saveAPIKey(keyDraft)
        if controller.keyErrorMessage == nil { keyDraft = "" }
    }

    private func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var isLocked: Bool { controller.state.isRunning }

    private func field(_ title: String, text: Binding<String>, prompt: String,
                       defaultValue: String, helpText: String) -> some View {
        SettingField(title, text: text, prompt: prompt, defaultValue: defaultValue,
                     helpText: helpText, isLocked: isLocked)
    }

    // MARK: - File pickers

    private func chooseLocalModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            localModelDir = url.path
            if localModelId.isEmpty {
                let name = url.lastPathComponent
                localModelId = "local/\(name)"
            }
        }
    }

    private func chooseDraftModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            localDraftModel = url.path
        }
    }

    private func chooseMmproj() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .item]
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            localMmproj = url.path
        }
    }

    private struct LocalModelInfo {
        let name: String
        let path: String
        let size: String
    }

    private func localModelInfo() -> LocalModelInfo {
        let url = URL(fileURLWithPath: localModelDir)
        var totalSize: Int64 = 0
        func walk(_ path: URL) {
            guard let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.fileSizeKey]) else { return }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                totalSize += Int64(values.fileSize ?? 0)
            }
        }
        walk(url)
        return LocalModelInfo(
            name: url.lastPathComponent,
            path: localModelDir,
            size: ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        )
    }

    private func prepareLocalModel() {
        isPreparing = true
        preparerState = .preparing(progress: 0)
        preparerOutput = ""

        Task {
            let preparer = SplashModelPreparer()
            preparer.port = 8002
            preparer.executablePath = controller.executable?.path ?? "splash-m1"  // Use a different port to avoid conflicts

            let modelId = localModelId.isEmpty ? "local/default" : localModelId

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await preparer.prepare(
                        modelId: modelId,
                        modelDirectory: localModelDir,
                        draftModel: localDraftModel.isEmpty ? nil : localDraftModel,
                        mmproj: localMmproj.isEmpty ? nil : localMmproj,
                        maxMemory: nil
                    ) { line in
                        Task { @MainActor in
                            preparerOutput += line + "\n"
                        }
                    }
                }
            }

            await MainActor.run {
                isPreparing = false
                preparerState = preparer.state
            }
        }
    }
}
