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
        case .invalidModel: return "El archivo no tiene una cabecera GGUF válida."
        case .couldNotLoadWeights: return "llama.cpp no pudo cargar los pesos. Revisa el registro."
        case .couldNotInitializeContext: return "llama.cpp no pudo inicializar el contexto. Revisa el registro."
        case .invalidPrompt: return "El prompt está vacío."
        case .contextExceeded: return "El prompt excede el contexto."
        case .decodeFailed: return "llama.cpp no pudo generar la respuesta."
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

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var progress: Float { lock.withLock { fraction } }

    func update(_ progress: Float) -> Bool {
        lock.withLock {
            fraction = progress
            return !cancelled
        }
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

    nonisolated let contextTokens: Int
    nonisolated let supportsTools: Bool
    private var n_len: Int32 { Int32(contextTokens) }
    var n_cur: Int32 = 0

    var n_decode: Int32 = 0

    init(model: OpaquePointer, context: OpaquePointer) {
        self.model = model
        self.context = context
        self.contextTokens = Int(llama_n_ctx_seq(context))
        var architecture = [CChar](repeating: 0, count: 64)
        let length = llama_model_meta_val_str(model, "general.architecture", &architecture, 64)
        self.supportsTools = length > 0 && ["qwen35", "qwen35moe"].contains(String(cString: architecture))
        self.tokens_list = []
        self.batch = llama_batch_init(512, 0, 1)
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

    static func create_context(url: URL, useMetal: Bool, requestedContext: Int,
                               control: ModelLoadControl) throws -> LlamaContext {
        try verifyGGUF(url)
        if control.isCancelled { throw CancellationError() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        DiagnosticLog.shared.write("GGUF \(url.lastPathComponent), \(size) bytes. Memoria disponible para la app: \(os_proc_available_memory()) bytes. Motor: \(useMetal ? "Metal" : "CPU").")
        llama_log_set({ level, message, _ in
            guard level != GGML_LOG_LEVEL_DEBUG, let message else { return }
            DiagnosticLog.shared.write(String(cString: message), source: "llama.cpp")
        }, nil)
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

        let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        let trained = Int(llama_model_n_ctx_train(model))
        let contextSize = trained > 0 ? min(requestedContext, trained) : requestedContext
        DiagnosticLog.shared.write("Contexto solicitado: \(requestedContext) tokens. Límite del GGUF: \(trained). Inicializando \(contextSize) tokens con \(n_threads) hilos.")

        var ctx_params = llama_context_default_params()
        ctx_params.n_ctx = UInt32(contextSize)
        ctx_params.n_batch = 512
        ctx_params.n_threads       = Int32(n_threads)
        ctx_params.n_threads_batch = Int32(n_threads)
        ctx_params.offload_kqv = enableGPU
        ctx_params.op_offload = enableGPU

        let context = llama_init_from_model(model, ctx_params)
        guard let context else {
            llama_model_free(model)
            llama_backend_free()
            throw LlamaError.couldNotInitializeContext
        }

        return LlamaContext(model: model, context: context)
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

    func completion_init(_ messages: [ChatMessage], toolPrompt: String?, control: ModelLoadControl) throws {
        clear()
        llama_sampler_reset(sampling)
        is_done = false
        tokens_list = tokenize(text: toolPrompt ?? chatPrompt(messages), add_bos: true, parseSpecial: true)
        guard !tokens_list.isEmpty else { throw LlamaError.invalidPrompt }
        guard tokens_list.count < Int(n_len) else { throw LlamaError.contextExceeded }
        for start in stride(from: 0, to: tokens_list.count, by: 512) {
            try Task.checkCancellation()
            if control.isCancelled { throw CancellationError() }
            llama_batch_clear(&batch)
            let end = min(start + 512, tokens_list.count)
            for index in start..<end {
                llama_batch_add(&batch, tokens_list[index], Int32(index), [0], index == tokens_list.count - 1)
            }
            guard llama_decode(context, batch) == 0 else { throw LlamaError.decodeFailed }
        }
        n_cur = Int32(tokens_list.count)
    }

    func completion_loop() throws -> String {
        var new_token_id: llama_token = 0

        new_token_id = llama_sampler_sample(sampling, context, batch.n_tokens - 1)

        if llama_vocab_is_eog(vocab, new_token_id) || n_cur == n_len {
            print("\n")
            is_done = true
            let new_token_str = String(cString: temporary_invalid_cchars + [0])
            temporary_invalid_cchars.removeAll()
            return new_token_str
        }

        let new_token_cchars = token_to_piece(token: new_token_id)
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
        var pp_avg: Double = 0
        var tg_avg: Double = 0

        var pp_std: Double = 0
        var tg_std: Double = 0

        for _ in 0..<nr {
            // bench prompt processing

            llama_batch_clear(&batch)

            let n_tokens = pp

            for i in 0..<n_tokens {
                llama_batch_add(&batch, 0, Int32(i), [0], false)
            }
            batch.logits[Int(batch.n_tokens) - 1] = 1 // true

            llama_memory_clear(llama_get_memory(context), false)

            let t_pp_start = DispatchTime.now().uptimeNanoseconds / 1000;

            if llama_decode(context, batch) != 0 {
                print("llama_decode() failed during prompt")
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
        tokens_list.removeAll()
        temporary_invalid_cchars.removeAll()
        llama_memory_clear(llama_get_memory(context), true)
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
