import Foundation
import Network
import UIKit

func stateText(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, tableName: "State", comment: "")
    return arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
}

final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()
    private let lock = NSLock()
    private let clock = ISO8601DateFormatter()
    private var lines: [String] = []
    private var handle: FileHandle?
    private var bytesWritten = 0
    let file: URL

    private init() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        file = folder.appendingPathComponent("CodeCrisol-\(UUID().uuidString.prefix(8)).log")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.createFile(atPath: file.path, contents: nil) {
                handle = try FileHandle(forWritingTo: file)
            } else {
                lines.append("No se pudo crear el archivo de diagnóstico.")
            }
        } catch {
            lines.append("No se pudo abrir el registro: \(error.localizedDescription)")
        }
    }

    func write(_ message: String, source: String = "App") {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.withLock {
            let line = "\(clock.string(from: Date())) [\(source)] \(text)"
            lines.append(line)
            if lines.count > 250 { lines.removeFirst(lines.count - 250) }
            guard let handle else { return }
            do {
                let data = Data((line + "\n").utf8)
                if bytesWritten + data.count > 2_097_152 {
                    try handle.seek(toOffset: 0)
                    try handle.truncate(atOffset: 0)
                    bytesWritten = 0
                }
                try handle.write(contentsOf: data)
                bytesWritten += data.count
            } catch {
                lines.append("No se pudo guardar el registro: \(error.localizedDescription)")
                self.handle = nil
            }
        }
    }

    func recent() -> [String] { lock.withLock { lines } }
}

enum CompletionError: Error {
    case busy
    case noModel
}

struct CompletionUsage {
    let prompt: Int
    let cachedPrompt: Int
    let output: Int
    let finishReason: String
}

struct PrefillProgress {
    let processed: Int
    let total: Int
    let cached: Int
}

struct AgentActivity {
    let id: UUID
    var status: String
    var thought = ""
    var isRunning = true
}

private struct ModelProfile: Codable {
    let context: Int
    let metal: Bool
    let compactKV: Bool
    var reasoning: Int
    var prefillThreads: Int? = nil
    var decodeThreads: Int? = nil
    var prefillBatch: Int? = nil
}

struct Model: Identifiable {
    var id: String { filename }
    var name: String
    var url: String
    var filename: String
    var source: String?
    var forOpenCode = false
}

struct DownloadProgress {
    let received: Int64
    let total: Int64?
    let lastUpdate: Date

    var fraction: Double? {
        total.map { min(Double(received) / Double($0), 1) }
    }

    var detail: String {
        let bytes = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let total, let fraction else { return stateText("download.received", bytes) }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return stateText("download.progress", Int(fraction * 100).formatted(), bytes, size)
    }
}

private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let id = UUID()
    let destination: URL
    private let update: (UUID, DownloadProgress) -> Void
    private let finish: (UUID, Result<Void, Error>) -> Void
    private var task: URLSessionDownloadTask?
    private var result: Result<Void, Error>?
    private var lastLoggedBytes: Int64 = 0
    private var lastLoggedPercent = -10
    private var lastUpdate = Date.distantPast
    private let started = Date()

    init(destination: URL, update: @escaping (UUID, DownloadProgress) -> Void,
         finish: @escaping (UUID, Result<Void, Error>) -> Void) {
        self.destination = destination
        self.update = update
        self.finish = finish
    }

    func start(_ url: URL) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: url)
        task?.resume()
        session.finishTasksAndInvalidate()
    }

    func cancel() { task?.cancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        let progress = DownloadProgress(received: totalBytesWritten, total: total, lastUpdate: now)
        if now.timeIntervalSince(lastUpdate) >= 0.3 || total == totalBytesWritten {
            lastUpdate = now
            update(id, progress)
        }
        let percent = progress.fraction.map { Int($0 * 100) }
        if percent.map({ $0 >= lastLoggedPercent + 10 || ($0 == 100 && lastLoggedPercent < 100) })
            ?? (totalBytesWritten - lastLoggedBytes >= 64 * 1024 * 1024) {
            lastLoggedBytes = totalBytesWritten
            lastLoggedPercent = percent ?? lastLoggedPercent
            DiagnosticLog.shared.write("\(destination.lastPathComponent) · \(progress.detail)", source: "Descarga")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        result = Result {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                throw NSError(domain: "Descarga", code: code,
                              userInfo: [NSLocalizedDescriptionKey: stateText("download.http", String(code))])
            }
            try LlamaContext.verifyGGUF(location)
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            try FileManager.default.moveItem(at: location, to: destination)
            let seconds = Int(Date().timeIntervalSince(started))
            DiagnosticLog.shared.write("HTTP \(code) · \(size) bytes verificados y guardados en \(seconds) s.", source: "Descarga")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = result ?? .failure(error ?? URLError(.unknown))
        finish(id, outcome)
    }
}

@MainActor
class LlamaState: ObservableObject {
    static let contextOptions = [4096, 8192, 16384, 32768, 65536, 98304, 114688, 131072]
    static let threadOptions = [0, 2, 4, 6, 8]
    static let prefillBatchOptions = [256, 512, 1024]
    private static let contextPreference = "requestedContextTokens"
    private static let portPreference = "lastListeningPort"
    private static let reasoningPreference = "reasoningLevel"
    private static let cachePreference = "compactKV"
    private static let profilesPreference = "ggufProfiles"
    @Published var messageLog = ""
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    @Published private(set) var loadedModel: String?
    @Published private(set) var activeContextTokens: Int?
    @Published private(set) var activeKVBytes: UInt64?
    @Published private(set) var prefillProgress: PrefillProgress?
    @Published private(set) var agentActivity: AgentActivity?
    private var pendingAgentThought = ""
    private var lastAgentThoughtUpdate: UInt64?
    @Published var requestedContextTokens: Int {
        didSet { UserDefaults.standard.set(requestedContextTokens, forKey: Self.contextPreference) }
    }
    @Published private(set) var loadingModel: String?
    @Published private(set) var loadStatus = stateText("model.empty")
    @Published private(set) var stoppingLoad = false
    @Published private(set) var busy = false
    @Published private(set) var transfer: String?
    @Published private(set) var downloadProgress: DownloadProgress?
    @Published var useMetal = true
    @Published var prefillThreads = 0
    @Published var decodeThreads = 0
    @Published var prefillBatch = 512
    @Published var reasoning: ReasoningLevel {
        didSet {
            UserDefaults.standard.set(reasoning.rawValue, forKey: Self.reasoningPreference)
            if let filename = loadedModelFile?.filename, var saved = modelProfiles[filename] {
                saved.reasoning = reasoning.rawValue
                storeProfile(saved, filename: filename)
            }
        }
    }
    @Published var compactKV: Bool {
        didSet { UserDefaults.standard.set(compactKV, forKey: Self.cachePreference) }
    }
    let NS_PER_S = 1_000_000_000.0

    @Published private(set) var serverRunning = false
    @Published private(set) var serverStarting = false
    @Published private(set) var serverAddress = ""
    @Published private(set) var serverError: String?
    private let httpServer = HTTPServer()
    private var serverRetry: Task<Void, Never>?
    private var serverAttempt = 0
    private var listeningCandidates: [NWEndpoint.Port] = []

    private var llamaContext: LlamaContext?
    private var loadedModelFile: Model?
    private var lastRequestedContext: Int?
    private var lastRequestedMetal: Bool?
    private var lastRequestedCompactKV: Bool?
    private var lastPrefillThreads: Int?
    private var lastDecodeThreads: Int?
    private var lastPrefillBatch: Int?
    private var loadControl: ModelLoadControl?
    private var transferTask: Task<Void, Never>?
    private var activeDownload: ModelDownload?
    private var generationControl: ModelLoadControl?
    private var waitingRequests = 0
    private var modelProfiles: [String: ModelProfile] = [:]
    var hasModel: Bool { llamaContext != nil }
    var supportsTools: Bool { llamaContext?.supportsTools == true }
    func isLoaded(_ model: Model) -> Bool { loadedModelFile?.filename == model.filename }
    var loadProgress: Float { loadControl?.progress ?? 0 }
    var isGenerating: Bool { generationControl != nil }
    var activeCacheLabel: String { lastRequestedCompactKV == true ? "Q8_0" : "FP16" }
    var hasPendingModelSettings: Bool {
        hasModel && (lastRequestedContext != requestedContextTokens || lastRequestedMetal != useMetal
                     || lastRequestedCompactKV != compactKV || lastPrefillThreads != prefillThreads
                     || lastDecodeThreads != decodeThreads || lastPrefillBatch != prefillBatch)
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.contextPreference)
        requestedContextTokens = Self.contextOptions.contains(saved) ? saved : Self.contextOptions[0]
        let thought = UserDefaults.standard.object(forKey: Self.reasoningPreference) as? Int
        reasoning = thought.flatMap(ReasoningLevel.init(rawValue:)) ?? .medium
        compactKV = UserDefaults.standard.bool(forKey: Self.cachePreference)
        if let savedProfiles = UserDefaults.standard.data(forKey: Self.profilesPreference),
           let decoded = try? JSONDecoder().decode([String: ModelProfile].self, from: savedProfiles) {
            modelProfiles = decoded
        }
        refreshModels()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "desconocida"
        DiagnosticLog.shared.write("CodeCrisol iniciado · build \(build) · \(ProcessInfo.processInfo.operatingSystemVersionString) · Increased Memory Limit: \(IncreasedMemoryStatus.current.rawValue).")
    }

    func refreshModels() {
        do {
            let documentsURL = getDocumentsDirectory()
            let modelURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            downloadedModels = modelURLs.filter {
                $0.pathExtension.lowercased() == "gguf" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }.map { file in
                defaultModels.first { $0.filename == file.lastPathComponent }
                    ?? Model(name: file.deletingPathExtension().lastPathComponent, url: "", filename: file.lastPathComponent, source: nil)
            }
            let local = Set(downloadedModels.map(\.filename))
            undownloadedModels = defaultModels.filter { !local.contains($0.filename) }
        } catch {
            report(stateText("library.readFailed", error.localizedDescription))
        }
    }

    func report(_ message: String) {
        loadStatus = message
        DiagnosticLog.shared.write(message)
    }

    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    private let defaultModels: [Model] = [
        Model(
            name: "Qwen 3.5 4B · Q4_K_M",
            url: "https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/Qwen_Qwen3.5-4B-Q4_K_M.gguf",
            filename: "qwen3.5-4b-Q4_K_M.gguf", source: stateText("catalog.speed"), forOpenCode: true
        ),
        Model(
            name: "Qwen 3.5 9B · Q4_K_M",
            url: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf",
            filename: "Qwen3.5-9B-Q4_K_M.gguf", source: stateText("catalog.qwenQ4"), forOpenCode: true
        ),
        Model(
            name: "Qwen 3.5 9B · Q3_K_M",
            url: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q3_K_M.gguf",
            filename: "Qwen3.5-9B-Q3_K_M.gguf", source: stateText("catalog.qwenQ3"), forOpenCode: true
        ),
        Model(
            name: "Qwen 3.5 9B · Q4_K_M",
            url: "https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf",
            filename: "LM-Studio-Qwen3.5-9B-Q4_K_M.gguf", source: stateText("catalog.qwenLM"), forOpenCode: true
        ),
        Model(
            name: "Ornith 1.5 9B · Q4_K_M",
            url: "https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF/resolve/main/Ornith-1.5-9B-Q4_K_M.gguf",
            filename: "Ornith-1.5-9B-Q4_K_M.gguf", source: stateText("catalog.ornith"), forOpenCode: true
        ),
        Model(
            name: "Qwen2.5-Coder 7B Instruct · Q4_K_M",
            url: "https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf",
            filename: "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf", source: stateText("catalog.coding")
        ),
        Model(
            name: "DeepSeek R1 Distill 7B · Q4_K_M",
            url: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
            filename: "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf", source: stateText("catalog.reasoning")
        ),
        Model(
            name: "DeepSeek Coder V2 Lite Instruct · Q3_K_S",
            url: "https://huggingface.co/bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF/resolve/main/DeepSeek-Coder-V2-Lite-Instruct-Q3_K_S.gguf",
            filename: "DeepSeek-Coder-V2-Lite-Instruct-Q3_K_S.gguf", source: stateText("catalog.lite")
        ),
        Model(
            name: "IBM Granite 4.0 Micro · Q4_K_M",
            url: "https://huggingface.co/ibm-granite/granite-4.0-micro-GGUF/resolve/main/granite-4.0-micro-Q4_K_M.gguf",
            filename: "granite-4.0-micro-Q4_K_M.gguf", source: stateText("catalog.granite")
        )
    ]

    func loadModel(_ model: Model) {
        guard !busy, loadingModel == nil else { return }
        if !isLoaded(model), let profile = modelProfiles[model.filename], Self.contextOptions.contains(profile.context) {
            requestedContextTokens = profile.context
            useMetal = profile.metal
            compactKV = profile.compactKV
            let savedPrefill = profile.prefillThreads ?? 0
            let savedDecode = profile.decodeThreads ?? 0
            prefillThreads = Self.threadOptions.contains(savedPrefill) ? savedPrefill : 0
            decodeThreads = Self.threadOptions.contains(savedDecode) ? savedDecode : 0
            let savedBatch = profile.prefillBatch ?? 512
            prefillBatch = Self.prefillBatchOptions.contains(savedBatch) ? savedBatch : 512
            // Clear the old file identity before applying the new reasoning setting.
            loadedModelFile = nil
            reasoning = ReasoningLevel(rawValue: profile.reasoning) ?? .medium
        }
        stopServer()
        llamaContext = nil
        loadedModel = nil
        loadedModelFile = nil
        activeContextTokens = nil
        activeKVBytes = nil
        let url = getDocumentsDirectory().appendingPathComponent(model.filename)
        let control = ModelLoadControl()
        let metal = useMetal
        let requestedContext = requestedContextTokens
        let compactCache = compactKV
        let batchThreads = prefillThreads
        let generationThreads = decodeThreads
        let batchSize = prefillBatch
        loadControl = control
        loadingModel = model.name
        report(stateText("model.loading", model.name))
        Task {
            defer {
                loadControl = nil
                loadingModel = nil
                stoppingLoad = false
            }
            do {
                let context = try await Task.detached(priority: .userInitiated) {
                    try LlamaContext.create_context(url: url, useMetal: metal, requestedContext: requestedContext,
                                                    compactKV: compactCache, prefillThreads: batchThreads,
                                                    decodeThreads: generationThreads, prefillBatch: batchSize,
                                                    control: control)
                }.value
                if control.isCancelled { throw CancellationError() }
                llamaContext = context
                loadedModel = model.name
                loadedModelFile = model
                activeContextTokens = context.contextTokens
                activeKVBytes = context.kvBytes
                lastRequestedContext = requestedContext
                lastRequestedMetal = metal
                lastRequestedCompactKV = compactCache
                lastPrefillThreads = batchThreads
                lastDecodeThreads = generationThreads
                lastPrefillBatch = batchSize
                storeProfile(ModelProfile(context: requestedContext, metal: metal, compactKV: compactCache,
                                          reasoning: reasoning.rawValue, prefillThreads: batchThreads,
                                          decodeThreads: generationThreads, prefillBatch: batchSize), filename: model.filename)
                report(stateText("model.ready", model.name, metal ? "Metal" : "CPU", context.contextTokens.formatted()))
            } catch is CancellationError {
                report(stateText("model.loadCancelled"))
            } catch {
                report(stateText("model.loadFailed", model.name, error.localizedDescription))
            }
        }
    }

    private func storeProfile(_ profile: ModelProfile, filename: String) {
        modelProfiles[filename] = profile
        if let data = try? JSONEncoder().encode(modelProfiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesPreference)
        }
    }

    func reloadModel() {
        if let loadedModelFile { loadModel(loadedModelFile) }
    }

    func cancelLoad() {
        guard let loadControl else { return }
        stoppingLoad = true
        loadControl.cancel()
        report(stateText("model.cancelling"))
    }

    func stopGeneration() {
        generationControl?.cancel()
    }

    func unloadModel() {
        guard !busy, loadingModel == nil, hasModel else { return }
        stopServer()
        llamaContext = nil
        loadedModel = nil
        loadedModelFile = nil
        activeContextTokens = nil
        activeKVBytes = nil
        report(stateText("model.unloaded"))
    }

    func removeModel(_ model: Model) {
        guard loadingModel == nil, !isLoaded(model) else { return }
        do {
            try FileManager.default.removeItem(at: getDocumentsDirectory().appendingPathComponent(model.filename))
            refreshModels()
            DiagnosticLog.shared.write("Eliminado \(model.filename).")
        } catch {
            report(stateText("library.deleteFailed", error.localizedDescription))
        }
    }

    func download(_ url: URL, filename: String) {
        guard transfer == nil, url.scheme?.lowercased() == "https", url.host != nil,
              filename == (filename as NSString).lastPathComponent,
              (filename as NSString).pathExtension.lowercased() == "gguf" else {
            report(stateText("download.url"))
            return
        }
        let destination = getDocumentsDirectory().appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            refreshModels()
            if downloadedModels.contains(where: { $0.filename == filename }) {
                report(stateText("download.exists", filename))
            } else {
                report(stateText("download.conflict", filename))
            }
            return
        }
        transfer = filename
        downloadProgress = DownloadProgress(received: 0, total: nil, lastUpdate: Date())
        DiagnosticLog.shared.write("Iniciando \(filename) desde \(url.host ?? "").", source: "Descarga")
        let download = ModelDownload(destination: destination) { [weak self] id, progress in
            Task { @MainActor in
                guard let self, self.activeDownload?.id == id else { return }
                if progress.received >= (self.downloadProgress?.received ?? 0) {
                    self.downloadProgress = progress
                }
            }
        } finish: { [weak self] id, result in
            Task { @MainActor in
                guard let self, self.activeDownload?.id == id else { return }
                self.activeDownload = nil
                self.transfer = nil
                self.downloadProgress = nil
                switch result {
                case .success:
                    self.refreshModels()
                    self.report(stateText("download.done", filename))
                case .failure(let error):
                    let cancelled = (error as? URLError)?.code == .cancelled
                    self.report(cancelled ? stateText("download.cancelled") : stateText("download.failed", error.localizedDescription))
                }
            }
        }
        activeDownload = download
        download.start(url)
    }

    func cancelDownload() {
        if let activeDownload {
            DiagnosticLog.shared.write("Cancelación solicitada para \(activeDownload.destination.lastPathComponent).", source: "Descarga")
            activeDownload.cancel()
        }
        transferTask?.cancel()
    }

    func importModel(_ source: URL) {
        guard transfer == nil else { return }
        guard source.pathExtension.lowercased() == "gguf" else {
            report(stateText("import.extension"))
            return
        }
        transfer = source.lastPathComponent
        let destination = getDocumentsDirectory().appendingPathComponent(source.lastPathComponent)
        DiagnosticLog.shared.write("Importando \(source.lastPathComponent) desde Archivos.", source: "Importación")
        transferTask = Task {
            defer {
                transfer = nil
                transferTask = nil
            }
            do {
                let copy = Task.detached(priority: .utility) {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    var coordinationError: NSError?
                    var outcome: Result<Bool, Error>?
                    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
                        outcome = Result {
                            try Task.checkCancellation()
                            try LlamaContext.verifyGGUF(readableURL)
                            if readableURL.standardizedFileURL == destination.standardizedFileURL { return false }

                            let folder = destination.deletingLastPathComponent()
                            var target = destination
                            var suffix = 2
                            while FileManager.default.fileExists(atPath: target.path) {
                                let name = destination.deletingPathExtension().lastPathComponent
                                target = folder.appendingPathComponent("\(name) (\(suffix)).gguf")
                                suffix += 1
                            }
                            let staging = folder.appendingPathComponent(".\(UUID().uuidString)")
                            defer { try? FileManager.default.removeItem(at: staging) }
                            try FileManager.default.copyItem(at: readableURL, to: staging)
                            try Task.checkCancellation()
                            try FileManager.default.moveItem(at: staging, to: target)
                            return true
                        }
                    }
                    if let coordinationError { throw coordinationError }
                    guard let outcome else { throw CocoaError(.fileReadUnknown) }
                    return try outcome.get()
                }
                let imported = try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
                refreshModels()
                report(imported ? stateText("import.done", source.lastPathComponent) : stateText("import.exists"))
            } catch {
                report(Task.isCancelled ? stateText("import.cancelled") : stateText("import.failed", error.localizedDescription))
            }
        }
    }


    func complete(text: String) async {
        guard hasModel else { return }
        messageLog += text
        let start = DispatchTime.now().uptimeNanoseconds
        var firstOutput: UInt64?
        var visibleOutput = ToolOutput(parseTools: false)
        do {
            let usage = try await generate([ChatMessage(role: "user", content: text)], maxTokens: Int.max) { piece in
                let visible = try visibleOutput.append(piece)
                guard !visible.isEmpty else { return }
                if firstOutput == nil { firstOutput = DispatchTime.now().uptimeNanoseconds }
                self.messageLog += visible
            }
            messageLog += try visibleOutput.append("", final: true)
            messageLog += "\nDone\n"
            if let firstOutput {
                let latency = Double(firstOutput - start) / NS_PER_S
                let duration = Double(DispatchTime.now().uptimeNanoseconds - firstOutput) / NS_PER_S
                messageLog += "Time to first text: \(latency)s\n"
                if duration > 0, usage.output > 1 {
                    messageLog += "Generated \(Double(usage.output - 1) / duration) t/s\n"
                }
            }
        } catch {
            messageLog += "\nGeneration failed: \(error)\n"
        }
    }

    func bench() async {
        guard !busy, let llamaContext else { return }
        busy = true
        defer { busy = false }

        messageLog += "\n"
        messageLog += "Running benchmark...\n"
        messageLog += "Model info: "
        messageLog += await llamaContext.model_info() + "\n"

        let t_start = DispatchTime.now().uptimeNanoseconds
        let _ = await llamaContext.bench(pp: 8, tg: 4, pl: 1) // heat up
        let t_end = DispatchTime.now().uptimeNanoseconds

        let t_heat = Double(t_end - t_start) / NS_PER_S
        messageLog += "Heat up time: \(t_heat) seconds, please wait...\n"

        // if more than 5 seconds, then we're probably running on a slow device
        if t_heat > 5.0 {
            messageLog += "Heat up time is too long, aborting benchmark\n"
            return
        }

        let result = await llamaContext.bench(pp: 512, tg: 128, pl: 1, nr: 3)

        messageLog += "\(result)"
        messageLog += "\n"
    }

    func clear() async {
        guard !busy, let llamaContext else { return }
        busy = true
        defer { busy = false }

        await llamaContext.clear()
        messageLog = ""
    }

    // MARK: - HTTP Server

    func toggleServer() {
        if serverRunning || serverStarting {
            stopServer()
            return
        }
        restartServer()
    }

    func restartServer() {
        guard hasModel else { return }
        stopServer()
        serverError = nil
        serverStarting = true
        serverAttempt = 0
        let stored = UserDefaults.standard.integer(forKey: Self.portPreference)
        let preferred = UInt16(exactly: stored) ?? 0
        let primary = NWEndpoint.Port(rawValue: preferred == 0 ? 8080 : preferred)!
        let alternate = NWEndpoint.Port(rawValue: primary.rawValue == 8080 ? 8081 : 8080)!
        listeningCandidates = [primary, primary, alternate, .any]
        startListener()
    }

    private func startListener() {
        do {
            try httpServer.start(llamaState: self, port: listeningCandidates[serverAttempt])
        } catch {
            serverFailed(error)
        }
    }

    func serverReady(port: UInt16) {
        guard serverStarting else { return }
        serverStarting = false
        serverRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        serverAddress = "http://\(httpServer.getLocalIP()):\(port)/v1"
        UserDefaults.standard.set(Int(port), forKey: Self.portPreference)
        DiagnosticLog.shared.write("Servidor escuchando en \(serverAddress).")
    }

    func stopServer() {
        let wasActive = serverRunning || serverStarting
        serverRetry?.cancel()
        serverRetry = nil
        httpServer.stop()
        if wasActive {
            stopGeneration()
            UIApplication.shared.isIdleTimerDisabled = false
            DiagnosticLog.shared.write("Servidor detenido.")
        }
        serverRunning = false
        serverStarting = false
        serverAddress = ""
    }

    func serverFailed(_ error: Error) {
        DiagnosticLog.shared.write("Error del servidor: \(error.localizedDescription)")
        if serverStarting, let networkError = error as? NWError,
           case .posix(.EADDRINUSE) = networkError, serverAttempt + 1 < listeningCandidates.count {
            httpServer.stop()
            let occupied = listeningCandidates[serverAttempt].rawValue
            serverAttempt += 1
            let next = listeningCandidates[serverAttempt].rawValue
            DiagnosticLog.shared.write(next == 0 ? "Puerto \(occupied) ocupado. Buscando un puerto libre." : "Puerto \(occupied) ocupado. Intentando \(next).")
            serverRetry = Task {
                do { try await Task.sleep(nanoseconds: 400_000_000) }
                catch { return }
                serverRetry = nil
                if serverStarting { startListener() }
            }
            return
        }
        stopServer()
        serverError = error.localizedDescription
    }

    func appendAgentThought(_ text: String, for id: UUID) {
        guard let activity = agentActivity, activity.id == id, !text.isEmpty else { return }
        pendingAgentThought += text
        let now = DispatchTime.now().uptimeNanoseconds
        if activity.isRunning, let lastAgentThoughtUpdate, now - lastAgentThoughtUpdate < 125_000_000 {
            return
        }
        flushAgentThought()
        lastAgentThoughtUpdate = now
    }

    private func flushAgentThought() {
        guard !pendingAgentThought.isEmpty else { return }
        if var activity = agentActivity {
            activity.thought = String((activity.thought + pendingAgentThought).suffix(4096))
            agentActivity = activity
        }
        pendingAgentThought = ""
    }

    func generate(_ messages: [ChatMessage], maxTokens: Int,
                  fromServer: Bool = false,
                  toolPrompt: String? = nil,
                  usePromptCache: Bool = true,
                  activityID: UUID? = nil,
                  onText: (String) async throws -> Void) async throws -> CompletionUsage {
        if fromServer, busy {
            guard waitingRequests < 2 else { throw CompletionError.busy }
            waitingRequests += 1
            defer { waitingRequests -= 1 }
            let deadline = Date().addingTimeInterval(90)
            while busy && serverRunning {
                if Date() >= deadline { throw CompletionError.busy }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        guard let llamaContext, !fromServer || serverRunning else { throw CompletionError.noModel }
        guard !busy else { throw CompletionError.busy }
        let control = ModelLoadControl()
        generationControl = control
        let selectedReasoning = reasoning
        busy = true
        if let activityID {
            pendingAgentThought = ""
            lastAgentThoughtUpdate = nil
            agentActivity = AgentActivity(id: activityID, status: stateText("activity.prefill"))
        }
        func updateActivity(_ status: String, isRunning: Bool = true) {
            guard let activityID, var activity = agentActivity, activity.id == activityID else { return }
            activity.status = status
            activity.isRunning = isRunning
            agentActivity = activity
        }
        defer {
            if activityID != nil { flushAgentThought() }
            generationControl = nil
            prefillProgress = nil
            busy = false
        }

        let requestLabel = activityID.map { "chatcmpl-\($0.uuidString.prefix(8)) · " } ?? ""
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            control.sampleMemory(force: true)
            let prep = try await llamaContext.completion_init(messages, toolPrompt: toolPrompt,
                                                               reasoning: selectedReasoning, maxTokens: maxTokens,
                                                               cachePrompt: fromServer && usePromptCache, control: control) { processed, total, cached in
                self.prefillProgress = PrefillProgress(processed: processed, total: total, cached: cached)
            }
            let prefillEnd = DispatchTime.now().uptimeNanoseconds
            control.sampleMemory(force: true)
            control.logMemoryPeak("Prefill", request: requestLabel)
            prefillProgress = nil
            updateActivity(stateText("activity.decode"))
            let prompt = Int(await llamaContext.n_cur)
            let available = llamaContext.contextTokens - prompt
            let limit = min(maxTokens, available)
            var output = 0
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            if prep.thought > 0 { try await onText("<think>") }
            while output < limit {
                try Task.checkCancellation()
                if control.isCancelled { throw CancellationError() }
                let piece = try await llamaContext.completion_loop()
                if !piece.isEmpty { try await onText(piece) }
                let finished = await llamaContext.is_done
                if finished {
                    break
                }
                output += 1
                if output.isMultiple(of: 8) { control.sampleMemory() }
            }
            let stopped = await llamaContext.is_done
            if !stopped {
                let tail = await llamaContext.flushText()
                if !tail.isEmpty { try await onText(tail) }
            }
            let decodeEnd = DispatchTime.now().uptimeNanoseconds
            control.sampleMemory(force: true)
            control.logMemoryPeak("Prefill y generación", request: requestLabel)
            await llamaContext.finishRequest()
            if fromServer {
                let thoughtTokens = await llamaContext.thoughtTokens
                let prefillMs = Double(prefillEnd - started) / 1_000_000
                let decodeSeconds = Double(decodeEnd - decodeStart) / NS_PER_S
                let throughput = decodeSeconds > 0 ? Double(output) / decodeSeconds : 0
                let finish = stopped ? "stop" : "length"
                DiagnosticLog.shared.write(requestLabel + String(format: "Chat completado · entrada %d tokens · caché %d tokens · prefill %.1f ms · salida %d tokens · %.1f tok/s · generación %.1f ms", prompt, prep.cached, prefillMs, output, throughput, decodeSeconds * 1000) + " · fin \(finish)", source: "API")
                if llamaContext.supportsTools {
                    DiagnosticLog.shared.write("\(requestLabel)Pensamiento \(selectedReasoning.title) · \(thoughtTokens) tokens generados · presupuesto efectivo \(prep.thought) tokens.", source: "API")
                }
            }
            updateActivity(stateText("activity.done", prompt.formatted(), prep.cached.formatted(), output.formatted()), isRunning: false)
            return CompletionUsage(prompt: prompt, cachedPrompt: prep.cached, output: output, finishReason: stopped ? "stop" : "length")
        } catch {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            let prefillDetail = prefillProgress.map {
                " · prefill \($0.processed)/\($0.total) tokens · caché \($0.cached)"
            } ?? ""
            control.sampleMemory(force: true)
            control.logMemoryPeak("Generación interrumpida", request: requestLabel)
            await llamaContext.clear()
            updateActivity(error is CancellationError ? stateText("activity.cancelled") : stateText("activity.failed"), isRunning: false)
            DiagnosticLog.shared.write("\(requestLabel)Generación interrumpida · \(String(format: "%.1f", elapsedMs)) ms\(prefillDetail) · \(error.localizedDescription)", source: fromServer ? "API" : "App")
            throw error
        }
    }
}
