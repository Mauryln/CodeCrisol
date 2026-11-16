import Foundation
import llama
import os

enum LlamaError: LocalizedError {
    case invalidModel
    case couldNotLoadWeights
    case couldNotInitializeContext
    case invalidPrompt
    case contextExceeded
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidModel: return stateText("error.gguf")
        case .couldNotLoadWeights: return stateText("error.weights")
        case .couldNotInitializeContext: return stateText("error.context")
        case .invalidPrompt: return stateText("error.empty")
        case .contextExceeded: return stateText("error.exceeded")
        case .decodeFailed: return stateText("error.decode")
        }
    }
}

struct ChatMessage: Sendable {
    let role: String
    let content: String
}

final class ModelLoadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var fraction: Float = 0
    private var lastSample: UInt64 = 0
    private var peakFootprint: UInt64?
    private var peakMetal: UInt64?
    private var minimumAvailable: UInt64?
    private var peakThermal = ProcessInfo.ThermalState.nominal.rawValue

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var progress: Float { lock.withLock { fraction } }

    func update(_ progress: Float) -> Bool {
        sampleMemory()
        return lock.withLock {
            fraction = progress
            return !cancelled
        }
    }

    func sampleMemory(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldSample = lock.withLock {
            guard force || now - lastSample >= 1_000_000_000 else { return false }
            lastSample = now
            return true
        }
        guard shouldSample else { return }
        let snapshot = RuntimeMemorySample()
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        lock.withLock {
            if let bytes = snapshot.footprint { peakFootprint = max(peakFootprint ?? 0, bytes) }
            if let bytes = snapshot.metalAllocated { peakMetal = max(peakMetal ?? 0, bytes) }
            minimumAvailable = min(minimumAvailable ?? snapshot.available, snapshot.available)
            peakThermal = max(peakThermal, thermal)
        }
    }

    func logMemoryPeak(_ phase: String, request: String = "") {
        let samples = lock.withLock { (peakFootprint, peakMetal, minimumAvailable, peakThermal) }
        let footprint = samples.0.map(RuntimeMemorySample.gib) ?? "sin lectura"
        let metal = samples.1.map(RuntimeMemorySample.gib) ?? "sin lectura"
        let available = samples.2.map(RuntimeMemorySample.gib) ?? "sin lectura"
        let thermal: String
        switch ProcessInfo.ThermalState(rawValue: samples.3) {
        case .nominal?: thermal = "nominal"
        case .fair?: thermal = "moderado"
        case .serious?: thermal = "grave"
        case .critical?: thermal = "crítico"
        default: thermal = "desconocido"
        }
        DiagnosticLog.shared.write("\(request)\(phase) · máximo observado · Huella \(footprint) · Metal \(metal) · disponible mínimo \(available) · estado térmico máximo \(thermal).", source: "Memoria")
    }
}

func llama_batch_clear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
    batch.token   [Int(batch.n_tokens)] = id
    batch.pos     [Int(batch.n_tokens)] = pos
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
    for i in 0..<seq_ids.count {
        batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i]
    }
    batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0

    batch.n_tokens += 1
}

actor LlamaContext {
    private var model: OpaquePointer
    private var context: OpaquePointer
    private var vocab: OpaquePointer
    private var sampling: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch
    private var tokens_list: [llama_token]
    var is_done: Bool = false

    /// This variable is used to store temporarily invalid cchars
    private var temporary_invalid_cchars: [CChar]
    private var remainingThought: Int?
    private(set) var thoughtTokens = 0
    private var thoughtEndToken: llama_token?
    private var prefixCheckpoint: (tokens: [llama_token], state: Data)?
    nonisolated let kvBytes: UInt64?

    nonisolated let contextTokens: Int
    nonisolated let supportsTools: Bool
    private let prefillBatch: Int
    private var n_len: Int32 { Int32(contextTokens) }
    var n_cur: Int32 = 0

    var n_decode: Int32 = 0

    init(model: OpaquePointer, context: OpaquePointer, kvBytes: UInt64?) {
        self.model = model
        self.context = context
        self.kvBytes = kvBytes
        self.contextTokens = Int(llama_n_ctx_seq(context))
        let batchSize = llama_n_batch(context)
        self.prefillBatch = Int(batchSize)
        var architecture = [CChar](repeating: 0, count: 64)
        let length = llama_model_meta_val_str(model, "general.architecture", &architecture, 64)
        self.supportsTools = length > 0 && ["qwen35", "qwen35moe"].contains(String(cString: architecture))
        self.tokens_list = []
        self.batch = llama_batch_init(Int32(batchSize), 0, 1)
        self.temporary_invalid_cchars = []
        let sparams = llama_sampler_chain_default_params()
        self.sampling = llama_sampler_chain_init(sparams)
        llama_sampler_chain_add(self.sampling, llama_sampler_init_temp(0.4))
        llama_sampler_chain_add(self.sampling, llama_sampler_init_dist(1234))
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_sampler_free(sampling)
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    static func verifyGGUF(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 24) ?? Data()
        guard header.count == 24, header.prefix(4) == Data("GGUF".utf8) else {
            throw LlamaError.invalidModel
        }
    }

    static func create_context(url: URL, useMetal: Bool, requestedContext: Int, compactKV: Bool,
                               prefillThreads: Int, decodeThreads: Int, prefillBatch: Int,
                               control: ModelLoadControl) throws -> LlamaContext {
        try verifyGGUF(url)
        if control.isCancelled { throw CancellationError() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        control.sampleMemory(force: true)
        DiagnosticLog.shared.write("GGUF \(url.lastPathComponent), \(size) bytes. Memoria disponible para la app: \(os_proc_available_memory()) bytes. Motor: \(useMetal ? "Metal" : "CPU").")
        let allocation = KVAllocation()
        let logger: ggml_log_callback = { level, message, data in
            guard level != GGML_LOG_LEVEL_DEBUG, let message else { return }
            let line = String(cString: message)
            if let data { Unmanaged<KVAllocation>.fromOpaque(data).takeUnretainedValue().record(line) }
            DiagnosticLog.shared.write(line, source: "llama.cpp")
        }
        llama_log_set(logger, Unmanaged.passUnretained(allocation).toOpaque())
        defer {
            llama_log_set(logger, nil)
            control.sampleMemory(force: true)
            control.logMemoryPeak("Carga")
        }
        llama_backend_init()
        var model_params = llama_model_default_params()
        model_params.progress_callback_user_data = Unmanaged.passUnretained(control).toOpaque()
        model_params.progress_callback = { progress, data in
            guard let data else { return false }
            return Unmanaged<ModelLoadControl>.fromOpaque(data).takeUnretainedValue().update(progress)
        }

#if targetEnvironment(simulator)
        let enableGPU = false
#else
        let enableGPU = useMetal
#endif
        if !enableGPU {
            model_params.n_gpu_layers = 0
            model_params.split_mode = LLAMA_SPLIT_MODE_NONE
            model_params.main_gpu = -1
        }
        let model = llama_model_load_from_file(url.path(percentEncoded: false), model_params)
        guard let model else {
            llama_backend_free()
            if control.isCancelled { throw CancellationError() }
            throw LlamaError.couldNotLoadWeights
        }
        if control.isCancelled {
            llama_model_free(model)
            llama_backend_free()
            throw CancellationError()
        }
        control.sampleMemory(force: true)

        let defaultThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        let batchThreads = prefillThreads == 0 ? defaultThreads : prefillThreads
        let generationThreads = decodeThreads == 0 ? defaultThreads : decodeThreads
        let trained = Int(llama_model_n_ctx_train(model))
        let contextSize = trained > 0 ? min(requestedContext, trained) : requestedContext
        DiagnosticLog.shared.write("Contexto solicitado: \(requestedContext) tokens. Límite del GGUF: \(trained). Inicializando \(contextSize) tokens · lote prefill \(prefillBatch) · hilos prefill \(batchThreads) · hilos generación \(generationThreads) · KV \(compactKV ? "Q8_0" : "FP16").")

        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = UInt32(contextSize)
        ctx_params.n_batch = UInt32(prefillBatch)
        ctx_params.n_ubatch = UInt32(prefillBatch)
        ctx_params.n_threads       = Int32(generationThreads)
        ctx_params.n_threads_batch = Int32(batchThreads)
        ctx_params.offload_kqv = enableGPU
        ctx_params.op_offload = enableGPU
        if compactKV {
            ctx_params.type_k = GGML_TYPE_Q8_0
            ctx_params.type_v = GGML_TYPE_Q8_0
            ctx_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        }

        let context = llama_init_from_model(model, ctx_params)
        guard let context else {
            llama_model_free(model)
            llama_backend_free()
            throw LlamaError.couldNotInitializeContext
        }

        return LlamaContext(model: model, context: context, kvBytes: allocation.bytes)
    }

    func model_info() -> String {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
        result.initialize(repeating: Int8(0), count: 256)
        defer {
            result.deallocate()
        }

        // TODO: this is probably very stupid way to get the string from C

        let nChars = llama_model_desc(model, result, 256)
        let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nChars))

        var SwiftString = ""
        for char in bufferPointer {
            SwiftString.append(Character(UnicodeScalar(UInt8(char))))
        }

        return SwiftString
    }

    func get_n_tokens() -> Int32 {
        return batch.n_tokens;
    }

    private func chatPrompt(_ messages: [ChatMessage]) -> String {
        if let template = llama_model_chat_template(model, nil) {
            var allocations: [UnsafeMutablePointer<CChar>] = []
            defer { allocations.forEach { free($0) } }
            var chat: [llama_chat_message] = []
            for message in messages {
                guard let role = strdup(message.role) else { break }
                allocations.append(role)
                guard let content = strdup(message.content) else { break }
                allocations.append(content)
                chat.append(llama_chat_message(role: UnsafePointer(role), content: UnsafePointer(content)))
            }
            if chat.count == messages.count {
                let length = llama_chat_apply_template(template, chat, chat.count, true, nil, 0)
                if length > 0, length <= 2_097_152 {
                    var buffer = [CChar](repeating: 0, count: Int(length) + 1)
                    let written = llama_chat_apply_template(template, chat, chat.count, true, &buffer, length + 1)
                    if written == length { return String(cString: buffer) }
                }
            }
        }
        DiagnosticLog.shared.write("Plantilla GGUF ausente o no reconocida. Se usará ChatML.", source: "llama.cpp")
        return messages.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>\n" }.joined()
            + "<|im_start|>assistant\n"
    }

    func completion_init(_ messages: [ChatMessage], toolPrompt: String?, reasoning: ReasoningLevel,
                         maxTokens: Int, cachePrompt: Bool, control: ModelLoadControl,
                         onProgress: @MainActor (Int, Int, Int) -> Void) async throws -> (thought: Int, cached: Int) {
        temporary_invalid_cchars.removeAll()
        llama_sampler_reset(sampling)
        is_done = false
        var prompt = toolPrompt ?? chatPrompt(messages)
        remainingThought = nil
        thoughtTokens = 0
        thoughtEndToken = nil
        if supportsTools, prompt.hasSuffix("<|im_start|>assistant\n") {
            if reasoning.budget(forOutputLimit: maxTokens) > 0 {
                let open = tokenize(text: prompt + "<think>\n", add_bos: true, parseSpecial: true)
                let budget = reasoning.budget(forOutputLimit: min(maxTokens, contextTokens - open.count))
                let end = tokenize(text: "</think>", add_bos: false, parseSpecial: true)
                if budget > 0, end.count == 1 {
                    tokens_list = open
                    remainingThought = budget
                    thoughtEndToken = end[0]
                }
            }
            if remainingThought == nil {
                prompt += "<think>\n\n</think>\n\n"
            }
        }
        if remainingThought == nil {
            tokens_list = tokenize(text: prompt, add_bos: true, parseSpecial: true)
        }
        guard !tokens_list.isEmpty else { throw LlamaError.invalidPrompt }
        guard tokens_list.count < Int(n_len) else { throw LlamaError.contextExceeded }
        let memory = llama_get_memory(context)
        let canCache = cachePrompt && supportsTools
        var cached = 0
        let flags = UInt32(LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY)
        if canCache, let saved = prefixCheckpoint,
           saved.tokens.count < tokens_list.count, tokens_list.starts(with: saved.tokens) {
            let restored = saved.state.withUnsafeBytes {
                llama_state_seq_set_data_ext(context, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, 0, flags)
            }
            if restored == saved.state.count, llama_memory_seq_rm(memory, 0, Int32(saved.tokens.count), -1) {
                cached = saved.tokens.count
            }
        }
        if cached == 0 {
            prefixCheckpoint = nil
            llama_memory_clear(memory, true)
        }
        // Keep the final assistant delimiter out of the snapshot so the prefix can
        // still match when OpenCode serializes the following tool call or message.
        let checkpointAt = max(0, (tokens_list.count - 64) / prefillBatch * prefillBatch)
        await onProgress(cached, tokens_list.count, cached)
        for start in stride(from: cached, to: tokens_list.count, by: prefillBatch) {
            try Task.checkCancellation()
            if control.isCancelled { throw CancellationError() }
            llama_batch_clear(&batch)
            let end = min(start + prefillBatch, tokens_list.count)
            for index in start..<end {
                llama_batch_add(&batch, tokens_list[index], Int32(index), [0], index == tokens_list.count - 1)
            }
            guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }
            if canCache, end == checkpointAt, end >= 1024 {
                prefixCheckpoint = nil
                let bytes = llama_state_seq_get_size_ext(context, 0, flags)
                let budget = min(96 * 1_048_576, os_proc_available_memory() / 8)
                if bytes > 0, bytes <= budget {
                    var snapshot = Data(count: bytes)
                    let written = snapshot.withUnsafeMutableBytes {
                        llama_state_seq_get_data_ext(context, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, 0, flags)
                    }
                    if written == bytes {
                        prefixCheckpoint = (Array(tokens_list.prefix(end)), snapshot)
                    }
                }
            }
            control.sampleMemory()
            await onProgress(end, tokens_list.count, cached)
        }
        n_cur = Int32(tokens_list.count)
        return (remainingThought ?? 0, cached)
    }

    func completion_loop() throws -> String {
        if n_cur >= n_len {
            is_done = true
            return flushText()
        }
        var new_token_id: llama_token
        if remainingThought == 0, let end = thoughtEndToken {
            new_token_id = end
        } else {
            new_token_id = llama_sampler_sample(sampling, context, batch.n_tokens - 1)
        }
        var closingThought = false
        if let remaining = remainingThought, let end = thoughtEndToken {
            if new_token_id == end || llama_vocab_is_eog(vocab, new_token_id) {
                new_token_id = end
                remainingThought = nil
                closingThought = true
            } else {
                remainingThought = remaining - 1
                thoughtTokens += 1
            }
        }
        if llama_vocab_is_eog(vocab, new_token_id), !closingThought {
            is_done = true
            return flushText()
        }

        let new_token_cchars = closingThought ? Array("</think>".utf8).map { CChar(bitPattern: $0) } : token_to_piece(token: new_token_id)
        temporary_invalid_cchars.append(contentsOf: new_token_cchars)
        let new_token_str: String
        if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else if (0 ..< temporary_invalid_cchars.count).contains(where: {$0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil}) {
            // in this case, at least the suffix of the temporary_invalid_cchars can be interpreted as UTF8 string
            let string = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            new_token_str = string
        } else {
            new_token_str = ""
        }

        llama_batch_clear(&batch)
        llama_batch_add(&batch, new_token_id, n_cur, [0], true)

        n_decode += 1
        n_cur    += 1

        guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }

        return new_token_str
    }

    func flushText() -> String {
        let text = String(decoding: temporary_invalid_cchars.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        temporary_invalid_cchars.removeAll()
        return text
    }

    func bench(pp: Int, tg: Int, pl: Int, nr: Int = 1) -> String {
        clear()
        var pp_avg: Double = 0
        var tg_avg: Double = 0

        var pp_std: Double = 0
        var tg_std: Double = 0

        for _ in 0..<nr {
            // bench prompt processing

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp_start = DispatchTime.now().uptimeNanoseconds / 1000;

            for start in stride(from: 0, to: pp, by: prefillBatch) {
                llama_batch_clear(&batch)
                for position in start..<min(start + prefillBatch, pp) {
                    llama_batch_add(&batch, 0, Int32(position), [0], position == pp - 1)
                }
                if llama_decode(context, batch) != 0 {
                    print("llama_decode() failed during prompt")
                    break
                }
            }
            llama_synchronize(context)

            let t_pp_end = DispatchTime.now().uptimeNanoseconds / 1000;

            // bench text generation

            llama_memory_clear(llama_get_memory(context), false)

            let t_tg_start = DispatchTime.now().uptimeNanoseconds / 1000;

            for i in 0..<tg {
                llama_batch_clear(&batch)

                for j in 0..<pl {
                    llama_batch_add(&batch, 0, Int32(i), [Int32(j)], true)
                }

                if llama_decode(context, batch) != 0 {
                    print("llama_decode() failed during text generation")
                }
                llama_synchronize(context)
            }

            let t_tg_end = DispatchTime.now().uptimeNanoseconds / 1000;

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp = Double(t_pp_end - t_pp_start) / 1000000.0
            let t_tg = Double(t_tg_end - t_tg_start) / 1000000.0

            let speed_pp = Double(pp)    / t_pp
            let speed_tg = Double(pl*tg) / t_tg

            pp_avg += speed_pp
            tg_avg += speed_tg

            pp_std += speed_pp * speed_pp
            tg_std += speed_tg * speed_tg

            print("pp \(speed_pp) t/s, tg \(speed_tg) t/s")
        }

        pp_avg /= Double(nr)
        tg_avg /= Double(nr)

        if nr > 1 {
            pp_std = sqrt(pp_std / Double(nr - 1) - pp_avg * pp_avg * Double(nr) / Double(nr - 1))
            tg_std = sqrt(tg_std / Double(nr - 1) - tg_avg * tg_avg * Double(nr) / Double(nr - 1))
        } else {
            pp_std = 0
            tg_std = 0
        }

        let model_desc     = model_info();
        let model_size     = String(format: "%.2f GiB", Double(llama_model_size(model)) / 1024.0 / 1024.0 / 1024.0);
        let model_n_params = String(format: "%.2f B", Double(llama_model_n_params(model)) / 1e9);
        let backend        = "Metal";
        let pp_avg_str     = String(format: "%.2f", pp_avg);
        let tg_avg_str     = String(format: "%.2f", tg_avg);
        let pp_std_str     = String(format: "%.2f", pp_std);
        let tg_std_str     = String(format: "%.2f", tg_std);

        var result = ""

        result += String("| model | size | params | backend | test | t/s |\n")
        result += String("| --- | --- | --- | --- | --- | --- |\n")
        result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | pp \(pp) | \(pp_avg_str) ± \(pp_std_str) |\n")
        result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | tg \(tg) | \(tg_avg_str) ± \(tg_std_str) |\n")

        return result;
    }

    func clear() {
        prefixCheckpoint = nil
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()
        llama_memory_clear(llama_get_memory(context), true)
    }

    func finishRequest() {
        if prefixCheckpoint == nil { clear() }
        else {
            tokens_list.removeAll()
            temporary_invalid_cchars.removeAll()
        }
    }

    private func tokenize(text: String, add_bos: Bool, parseSpecial: Bool) -> [llama_token] {
        let utf8Count = text.utf8.count
        let n_tokens = utf8Count + (add_bos ? 1 : 0) + 1
        let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
        let tokenCount = llama_tokenize(vocab, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, parseSpecial)

        var swiftTokens: [llama_token] = []
        for i in 0..<max(0, tokenCount) {
            swiftTokens.append(tokens[Int(i)])
        }

        tokens.deallocate()

        return swiftTokens
    }

    /// - note: The result does not contain null-terminator
    private func token_to_piece(token: llama_token) -> [CChar] {
        let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
        result.initialize(repeating: Int8(0), count: 8)
        defer {
            result.deallocate()
        }
        let nTokens = llama_token_to_piece(vocab, token, result, 8, 0, false)

        if nTokens < 0 {
            let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
            newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
            defer {
                newResult.deallocate()
            }
            let nNewTokens = llama_token_to_piece(vocab, token, newResult, -nTokens, 0, false)
            let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
            return Array(bufferPointer)
        } else {
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
            return Array(bufferPointer)
        }
    }
}
