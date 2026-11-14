import Foundation
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

@MainActor
class LlamaState: ObservableObject {
    @Published var messageLog = ""
    @Published var downloadedModels: [Model] = []
    @Published var undownloadedModels: [Model] = []
    @Published private(set) var loadedModel: String?
    @Published private(set) var loadingModel: String?
    @Published private(set) var loadStatus = "Selecciona un archivo GGUF para empezar."
    @Published private(set) var stoppingLoad = false
    @Published private(set) var busy = false
    @Published private(set) var transfer: String?
    @Published var useMetal = true
    let NS_PER_S = 1_000_000_000.0

    @Published var serverRunning = false
    @Published var serverAddress = ""
    let httpServer = HTTPServer(port: 8080)

    private var llamaContext: LlamaContext?
    private var loadControl: ModelLoadControl?
    private var transferTask: Task<Void, Never>?
    private var generationControl: ModelLoadControl?
    private var waitingRequests = 0
    var hasModel: Bool { llamaContext != nil }
    var loadProgress: Float { loadControl?.progress ?? 0 }
    var isGenerating: Bool { generationControl != nil }

    init() {
        refreshModels()
        DiagnosticLog.shared.write("CrucibleLLM iniciado.")
    }

    private func refreshModels() {
        do {
            let documentsURL = getDocumentsDirectory()
            let modelURLs = try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            downloadedModels = modelURLs.filter { $0.pathExtension.lowercased() == "gguf" }.sorted {
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
        let url = getDocumentsDirectory().appendingPathComponent(model.filename)
        let control = ModelLoadControl()
        let metal = useMetal
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
                    try LlamaContext.create_context(url: url, useMetal: metal, control: control)
                }.value
                if control.isCancelled { throw CancellationError() }
                llamaContext = context
                loadedModel = model.name
                report("\(model.name) listo · \(metal ? "Metal" : "CPU")")
            } catch is CancellationError {
                report("Carga cancelada.")
            } catch {
                report("Falló la carga de \(model.name): \(error.localizedDescription)")
            }
        }
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
        guard transferTask == nil, url.scheme?.lowercased() == "https", url.host != nil,
              filename == (filename as NSString).lastPathComponent,
              (filename as NSString).pathExtension.lowercased() == "gguf" else {
            report("Usa un enlace HTTPS directo a un archivo .gguf.")
            return
        }
        transfer = filename
        DiagnosticLog.shared.write("Descargando \(filename).")
        let destination = getDocumentsDirectory().appendingPathComponent(filename)
        transferTask = Task {
            defer {
                transfer = nil
                transferTask = nil
            }
            do {
                let (file, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    report("Descarga rechazada por el servidor (HTTP \(code)).")
                    return
                }
                try LlamaContext.verifyGGUF(file)
                try FileManager.default.moveItem(at: file, to: destination)
                refreshModels()
                report("\(filename) guardado.")
            } catch {
                let message = Task.isCancelled ? "Descarga cancelada." : "Falló la descarga: \(error.localizedDescription)"
                report(message)
            }
        }
    }

    func cancelDownload() {
        transferTask?.cancel()
    }

    func importModel(_ source: URL) {
        guard transferTask == nil, source.pathExtension.lowercased() == "gguf" else { return }
        transfer = source.lastPathComponent
        let destination = getDocumentsDirectory().appendingPathComponent(source.lastPathComponent)
        transferTask = Task {
            defer {
                transfer = nil
                transferTask = nil
            }
            do {
                let copy = Task.detached(priority: .utility) {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    try LlamaContext.verifyGGUF(source)
                    let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try FileManager.default.copyItem(at: source, to: staging)
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: staging, to: destination)
                }
                try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
                refreshModels()
                report("\(source.lastPathComponent) importado.")
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
            let usage = try await generate(text: text, maxTokens: Int.max, parseSpecial: false) { piece in
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
        if serverRunning {
            stopServer()
            return
        }
        guard hasModel else { return }
        do {
            try httpServer.start(llamaState: self)
            UIApplication.shared.isIdleTimerDisabled = true
            serverRunning = true
            let ip = httpServer.getLocalIP()
            serverAddress = "http://\(ip):8080/v1"
            DiagnosticLog.shared.write("Servidor iniciado en \(serverAddress).")
        } catch {
            report("No se pudo iniciar el servidor: \(error.localizedDescription)")
        }
    }

    func stopServer() {
        guard serverRunning else { return }
        httpServer.stop()
        stopGeneration()
        UIApplication.shared.isIdleTimerDisabled = false
        serverRunning = false
        serverAddress = ""
        DiagnosticLog.shared.write("Servidor detenido.")
    }

    func serverFailed(_ error: Error) {
        stopServer()
        report("Error del servidor: \(error.localizedDescription)")
    }

    func generate(text: String, maxTokens: Int, parseSpecial: Bool,
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
            try await llamaContext.completion_init(text: text, parseSpecial: parseSpecial, control: control)
            let prompt = Int(await llamaContext.n_cur)
            let available = Int(await llamaContext.n_len) - prompt
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
                DiagnosticLog.shared.write("Chat completado. Entrada: \(prompt) tokens. Salida: \(output) tokens.", source: "API")
            }
            return CompletionUsage(prompt: prompt, output: output, finishReason: stopped ? "stop" : "length")
        } catch {
            await llamaContext.clear()
            DiagnosticLog.shared.write("Generación interrumpida: \(error.localizedDescription)", source: fromServer ? "API" : "App")
            throw error
        }
    }
}
