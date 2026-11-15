import Foundation
import Network
import UIKit

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
        file = folder.appendingPathComponent("CrucibleLLM-\(UUID().uuidString.prefix(8)).log")
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
    let output: Int
    let finishReason: String
}

struct Model: Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var filename: String
    var status: String?
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
        guard let total, let fraction else { return "\(bytes) recibidos" }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(Int(fraction * 100)) % · \(bytes) de \(size)"
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
                              userInfo: [NSLocalizedDescriptionKey: "El servidor respondió HTTP \(code)."])
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
    static let contextOptions = [4096, 8192, 16384, 32768, 65536, 131072]
    private static let contextPreference = "requestedContextTokens"
    private static let portPreference = "lastListeningPort"
    @Published var messageLog = ""
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    @Published private(set) var loadedModel: String?
    @Published private(set) var activeContextTokens: Int?
    @Published var requestedContextTokens: Int {
        didSet { UserDefaults.standard.set(requestedContextTokens, forKey: Self.contextPreference) }
    }
    @Published private(set) var loadingModel: String?
    @Published private(set) var loadStatus = "Selecciona un archivo GGUF para empezar."
    @Published private(set) var stoppingLoad = false
    @Published private(set) var busy = false
    @Published private(set) var transfer: String?
    @Published private(set) var downloadProgress: DownloadProgress?
    @Published var useMetal = true
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
    private var loadControl: ModelLoadControl?
    private var transferTask: Task<Void, Never>?
    private var activeDownload: ModelDownload?
    private var generationControl: ModelLoadControl?
    private var waitingRequests = 0
    var hasModel: Bool { llamaContext != nil }
    var loadProgress: Float { loadControl?.progress ?? 0 }
    var isGenerating: Bool { generationControl != nil }
    var hasPendingModelSettings: Bool {
        hasModel && (lastRequestedContext != requestedContextTokens || lastRequestedMetal != useMetal)
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.contextPreference)
        requestedContextTokens = Self.contextOptions.contains(saved) ? saved : Self.contextOptions[0]
        refreshModels()
        DiagnosticLog.shared.write("CrucibleLLM iniciado.")
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
                    ?? Model(name: file.deletingPathExtension().lastPathComponent, url: "", filename: file.lastPathComponent, status: nil)
            }
            let local = Set(downloadedModels.map(\.filename))
            undownloadedModels = defaultModels.filter { !local.contains($0.filename) }
        } catch {
            report("No se pudo consultar la biblioteca: \(error.localizedDescription)")
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
            name: "Qwen3-8B (Q4_K_M, 5.03 GB)",
            url: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf?download=true",
            filename: "Qwen3-8B-Q4_K_M.gguf", status: "download"
        ),
        Model(
            name: "Gemma-3-4B-IT (Q4_K_M, 2.9 GiB)",
            url: "https://huggingface.co/bartowski/google_gemma-3-4b-it-GGUF/resolve/main/google_gemma-3-4b-it-Q4_K_M.gguf?download=true",
            filename: "gemma-3-4b-it-Q4_K_M.gguf", status: "download"
        ),
        Model(
            name: "Qwen-3.5-4B (Q4_K_M, 2.7 GiB)",
            url: "https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/Qwen_Qwen3.5-4B-Q4_K_M.gguf?download=true",
            filename: "qwen3.5-4b-Q4_K_M.gguf", status: "download"
        ),
        Model(name: "TinyLlama-1.1B (Q4_0, 0.6 GiB)",url: "https://huggingface.co/TheBloke/TinyLlama-1.1B-1T-OpenOrca-GGUF/resolve/main/tinyllama-1.1b-1t-openorca.Q4_0.gguf?download=true",filename: "tinyllama-1.1b-1t-openorca.Q4_0.gguf", status: "download"),
        Model(
            name: "TinyLlama-1.1B Chat (Q8_0, 1.1 GiB)",
            url: "https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q8_0.gguf?download=true",
            filename: "tinyllama-1.1b-chat-v1.0.Q8_0.gguf", status: "download"
        ),

        Model(
            name: "TinyLlama-1.1B (F16, 2.2 GiB)",
            url: "https://huggingface.co/ggml-org/models/resolve/main/tinyllama-1.1b/ggml-model-f16.gguf?download=true",
            filename: "tinyllama-1.1b-f16.gguf", status: "download"
        ),

        Model(
            name: "Phi-2.7B (Q4_0, 1.6 GiB)",
            url: "https://huggingface.co/ggml-org/models/resolve/main/phi-2/ggml-model-q4_0.gguf?download=true",
            filename: "phi-2-q4_0.gguf", status: "download"
        ),

        Model(
            name: "Phi-2.7B (Q8_0, 2.8 GiB)",
            url: "https://huggingface.co/ggml-org/models/resolve/main/phi-2/ggml-model-q8_0.gguf?download=true",
            filename: "phi-2-q8_0.gguf", status: "download"
        ),

        Model(
            name: "Mistral-7B-v0.1 (Q4_0, 3.8 GiB)",
            url: "https://huggingface.co/TheBloke/Mistral-7B-v0.1-GGUF/resolve/main/mistral-7b-v0.1.Q4_0.gguf?download=true",
            filename: "mistral-7b-v0.1.Q4_0.gguf", status: "download"
        ),
        Model(
            name: "OpenHermes-2.5-Mistral-7B (Q3_K_M, 3.52 GiB)",
            url: "https://huggingface.co/TheBloke/OpenHermes-2.5-Mistral-7B-GGUF/resolve/main/openhermes-2.5-mistral-7b.Q3_K_M.gguf?download=true",
            filename: "openhermes-2.5-mistral-7b.Q3_K_M.gguf", status: "download"
        )
    ]
    func loadModel(_ model: Model) {
        guard !busy, loadingModel == nil else { return }
        stopServer()
        llamaContext = nil
        loadedModel = nil
        loadedModelFile = nil
        activeContextTokens = nil
        let url = getDocumentsDirectory().appendingPathComponent(model.filename)
        let control = ModelLoadControl()
        let metal = useMetal
        let requestedContext = requestedContextTokens
        loadControl = control
        loadingModel = model.name
        report("Cargando \(model.name)…")
        Task {
            defer {
                loadControl = nil
                loadingModel = nil
                stoppingLoad = false
            }
            do {
                let context = try await Task.detached(priority: .userInitiated) {
                    try LlamaContext.create_context(url: url, useMetal: metal, requestedContext: requestedContext, control: control)
                }.value
                if control.isCancelled { throw CancellationError() }
                llamaContext = context
                loadedModel = model.name
                loadedModelFile = model
                activeContextTokens = context.contextTokens
                lastRequestedContext = requestedContext
                lastRequestedMetal = metal
                report("\(model.name) listo · \(metal ? "Metal" : "CPU") · \(context.contextTokens) tokens de contexto")
            } catch is CancellationError {
                report("Carga cancelada.")
            } catch {
                report("Falló la carga de \(model.name): \(error.localizedDescription)")
            }
        }
    }

    func reloadModel() {
        if let loadedModelFile { loadModel(loadedModelFile) }
    }

    func cancelLoad() {
        guard let loadControl else { return }
        stoppingLoad = true
        loadControl.cancel()
        report("Cancelando la carga…")
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
        report("Modelo descargado de la memoria.")
    }

    func removeModel(_ model: Model) {
        guard loadingModel == nil, loadedModel != model.name else { return }
        do {
            try FileManager.default.removeItem(at: getDocumentsDirectory().appendingPathComponent(model.filename))
            refreshModels()
            DiagnosticLog.shared.write("Eliminado \(model.filename).")
        } catch {
            report("No se pudo eliminar el archivo: \(error.localizedDescription)")
        }
    }

    func download(_ url: URL, filename: String) {
        guard transfer == nil, url.scheme?.lowercased() == "https", url.host != nil,
              filename == (filename as NSString).lastPathComponent,
              (filename as NSString).pathExtension.lowercased() == "gguf" else {
            report("Usa un enlace HTTPS directo a un archivo .gguf.")
            return
        }
        let destination = getDocumentsDirectory().appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            refreshModels()
            if downloadedModels.contains(where: { $0.filename == filename }) {
                report("\(filename) está en «En el iPad». Pulsa Cargar.")
            } else {
                report("Ya existe \(filename), pero no es un archivo GGUF de la biblioteca.")
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
                    self.report("\(filename) guardado.")
                case .failure(let error):
                    let cancelled = (error as? URLError)?.code == .cancelled
                    self.report(cancelled ? "Descarga cancelada." : "Falló la descarga: \(error.localizedDescription)")
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
            report("Selecciona un archivo con extensión .gguf.")
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
                report(imported ? "Modelo importado: \(source.lastPathComponent)." : "El modelo ya está en la biblioteca.")
            } catch {
                report(Task.isCancelled ? "Importación cancelada." : "Falló la importación: \(error.localizedDescription)")
            }
        }
    }


    func complete(text: String) async {
        guard hasModel else { return }
        messageLog += text
        let start = DispatchTime.now().uptimeNanoseconds
        var firstOutput: UInt64?
        do {
            let usage = try await generate([ChatMessage(role: "user", content: text)], maxTokens: Int.max) { piece in
                if firstOutput == nil { firstOutput = DispatchTime.now().uptimeNanoseconds }
                self.messageLog += piece
            }
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
        let primary = UInt16(exactly: stored).flatMap { $0 == 0 ? nil : NWEndpoint.Port(rawValue: $0) }
            ?? NWEndpoint.Port(rawValue: 8080)!
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

    func generate(_ messages: [ChatMessage], maxTokens: Int,
                  fromServer: Bool = false,
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
        busy = true
        defer {
            generationControl = nil
            busy = false
        }

        do {
            let started = DispatchTime.now().uptimeNanoseconds
            try await llamaContext.completion_init(messages, control: control)
            let prefillEnd = DispatchTime.now().uptimeNanoseconds
            let prompt = Int(await llamaContext.n_cur)
            let available = llamaContext.contextTokens - prompt
            let limit = min(maxTokens, available)
            var output = 0
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
            }
            let stopped = await llamaContext.is_done
            if !stopped {
                let tail = await llamaContext.flushText()
                if !tail.isEmpty { try await onText(tail) }
            }
            await llamaContext.clear()
            if fromServer {
                let prefillMs = Double(prefillEnd - started) / 1_000_000
                let decodeSeconds = Double(DispatchTime.now().uptimeNanoseconds - prefillEnd) / NS_PER_S
                let throughput = decodeSeconds > 0 ? Double(output) / decodeSeconds : 0
                DiagnosticLog.shared.write(String(format: "Chat completado · entrada %d tokens · prefill %.1f ms · salida %d tokens · %.1f tok/s", prompt, prefillMs, output, throughput), source: "API")
            }
            return CompletionUsage(prompt: prompt, output: output, finishReason: stopped ? "stop" : "length")
        } catch {
            await llamaContext.clear()
            DiagnosticLog.shared.write("Generación interrumpida: \(error.localizedDescription)", source: fromServer ? "API" : "App")
            throw error
        }
    }
}
