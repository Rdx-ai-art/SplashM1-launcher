import Foundation

/// Manages the background download and weight preparation of a local Splash model.
/// Runs `splash-m1 serve`, captures output via callback, and reports progress state.
final class SplashModelPreparer: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(progress: Float)
        case ready(modelId: String)
        case failed(message: String)

        var isFinal: Bool {
            switch self {
            case .idle, .preparing: return false
            case .ready, .failed: return true
            }
        }
    }

    @Published private(set) var state: State = .idle

    private var process: Process?
    private var partialLine = Data()
    private var currentModelId: String?

    /// The port this preparer uses. Defaults to 8002 so it does not conflict
    /// with an already-running Splash server on 8000 or 8001.
    var port: Int = 8002

    /// Full path to the splash-m1 executable. Set by the caller.
    var executablePath: String = "splash-m1"

    /// Runs Splash to download and prepare a local model.
    /// The outputHandler callback receives each line of output.
    func prepare(
        modelId: String,
        modelDirectory: String,
        draftModel: String?,
        mmproj: String?,
        maxMemory: String?,
        outputHandler: ((String) -> Void)?
    ) {
        guard state == .idle else { return }
        guard !modelDirectory.isEmpty else {
            outputHandler?("Error: Please select a local model directory first.")
            state = .failed(message: "No model directory selected")
            return
        }

        let executable = executablePath
        var args = [
            "serve",
            "--model", modelId,
            "--model-dir", modelDirectory,
            "--port", String(port),
            "--no-webui",
        ]
        if let draftModel { args += ["--draft-model", draftModel] }
        if let mmproj { args += ["--mmproj", mmproj] }
        if let maxMemory, !maxMemory.isEmpty { args += ["--max-memory", maxMemory] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        partialLine = Data()
        currentModelId = nil
        state = .preparing(progress: 0)

        self.process = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.processPipeData(data, outputHandler: outputHandler)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleExit()
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.state = .failed(message: "Could not start: \(error.localizedDescription)")
            }
        }
    }

    func processPipeData(_ data: Data, outputHandler: ((String) -> Void)?) {
        var buffer = partialLine + data
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            processLine(line)
            outputHandler?(line)
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        partialLine = Data(buffer.suffix(4_096))
    }

    private func processLine(_ line: String) {
        // Check for model identity line (Splash prints model info during startup)
        if line.range(of: "identity") != nil {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 {
                currentModelId = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        // Progress: Splash prints download progress like "Downloading …"
        if line.contains("Downloading") || line.contains("Progress") {
            if let range = line.range(of: #"\d+%"#) {
                let text = String(describing: range).dropLast()
                if let percent = Int(text), percent > 0 {
                    state = .preparing(progress: Float(percent) / 100.0)
                }
            }
        }

        // Weight preparation progress
        if line.contains("Preparing") || line.contains("preparing") {
            state = .preparing(progress: 0.5)
        }

        // Ready signal
        if line.contains("Ready") || line.contains("ready") {
            let modelId = currentModelId ?? "local/default"
            state = .ready(modelId: modelId)
        }

        // Error signal
        if line.contains("Error") || line.contains("error") {
            let msg = line
                .replacingOccurrences(of: "Error", with: "")
                .replacingOccurrences(of: "error", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !msg.isEmpty {
                state = .failed(message: msg)
            }
        }
    }

    private func handleExit() {
        process = nil

        // If we didn't already report ready or failed, check if output indicates success
        if case .idle = state {
            // Use the last line of output to check for success/failure
            // Since we don't store all output, just report based on state
            if state == .idle {
                // The process exited without triggering Ready or Error, which could
                // mean it completed silently or failed silently
                // Default to a generic failure
                state = .failed(message: "Splash exited without a Ready message. Check the output for details.")
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func shellQuote(_ arg: String) -> String {
        let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    deinit {
        process?.terminate()
    }
}
