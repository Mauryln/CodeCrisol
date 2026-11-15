import Foundation
import Network

/// Minimal HTTP server that serves an OpenAI-compatible chat completions API
@MainActor
final class HTTPServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private weak var llamaState: LlamaState?

    func start(llamaState: LlamaState, port: NWEndpoint.Port) throws {
        stop()
        self.llamaState = llamaState
        let current = try NWListener(using: .tcp, on: port)
        listener = current
        current.newConnectionHandler = { [weak self, weak current] connection in
            MainActor.assumeIsolated {
                guard let self, let current, self.listener === current else {
                    connection.cancel()
                    return
                }
                self.handleConnection(connection)
            }
        }
        current.stateUpdateHandler = { [weak self, weak current, weak llamaState] state in
            MainActor.assumeIsolated {
                guard let current, self?.listener === current else { return }
                switch state {
                case .ready:
                    if let port = current.port { llamaState?.serverReady(port: port.rawValue) }
                case .failed(let error), .waiting(let error):
                    llamaState?.serverFailed(error)
                default:
                    break
                }
            }
        }
        // Keep Network.framework callbacks ordered with changes to UI and listener state.
        current.start(queue: .main)
    }

    func stop() {
        let current = listener
        listener = nil
        current?.cancel()
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee, let socketAddress = interface.ifa_addr else { continue }
                let addrFamily = socketAddress.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func handleConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                MainActor.assumeIsolated {
                    self?.requests.removeValue(forKey: id)?.cancel()
                    self?.connections.removeValue(forKey: id)?.cancel()
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, finished, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[ObjectIdentifier(connection)] != nil, error == nil else {
                    connection.cancel()
                    return
                }
                self.processReceived(data, finished: finished, buffer: buffer, connection: connection)
            }
        }
    }

    private func processReceived(_ data: Data?, finished: Bool, buffer: Data, connection: NWConnection) {
        var request = buffer
        if let data { request.append(data) }
        if let separator = request.range(of: Data("\r\n\r\n".utf8)),
           separator.lowerBound <= 16384,
           let headers = String(data: request[..<separator.lowerBound], encoding: .utf8) {
            let fields = headers.components(separatedBy: "\r\n").dropFirst().compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (parts[0].lowercased(), parts[1].trimmingCharacters(in: .whitespaces))
            }
            let lengths = fields.filter { $0.0 == "content-length" }
            guard !fields.contains(where: { $0.0 == "transfer-encoding" }),
                  lengths.count <= 1,
                  let length = Int(lengths.first?.1 ?? "0"), length >= 0 else {
                self.sendError(connection, status: "400 Bad Request", message: "Expected a valid Content-Length.")
                return
            }
            guard length <= 1_048_576 else {
                self.sendError(connection, status: "413 Content Too Large", message: "Request body exceeds 1 MiB.")
                return
            }
            let bodyEnd = separator.upperBound + length
            if request.count >= bodyEnd {
                self.routeRequest(headers, body: Data(request[separator.upperBound..<bodyEnd]), connection: connection)
                return
            }
        } else if request.count > 16384 {
            self.sendError(connection, status: "431 Request Header Fields Too Large", message: "Request headers exceed 16 KiB.")
            return
        }
        if finished {
            self.sendError(connection, status: "400 Bad Request", message: "Incomplete HTTP request.")
        } else {
            self.receiveRequest(connection, buffer: request)
        }
    }

    private func routeRequest(_ request: String, body: Data, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Bad Request\"}")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Bad Request\"}")
            return
        }

        let method = parts[0]
        let path = parts[1]
        DiagnosticLog.shared.write("\(method) \(String(path.prefix(160)))", source: "API")

        // CORS headers for all responses
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: "200 OK", body: "", extraHeaders: [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, POST, OPTIONS",
                "Access-Control-Allow-Headers: Content-Type, Authorization"
            ])
            return
        }

        switch path {
        case "/":
            sendResponse(connection: connection, status: "200 OK", body: "Crucible LLM Server is running")
        case "/v1/models", "/api/tags":
            handleModels(connection: connection)
        case "/v1/chat/completions":
            if method == "POST" {
                handleChatCompletion(body: body, connection: connection)
            } else {
                sendResponse(connection: connection, status: "405 Method Not Allowed", body: "{\"error\":\"Method Not Allowed\"}")
            }
        default:
            sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Not Found\"}")
        }
    }

    private func handleModels(connection: NWConnection) {
        Task { @MainActor in
            let models: [[String: Any]]
            if let size = self.llamaState?.activeContextTokens {
                models = [["id": "local", "object": "model", "created": 0, "owned_by": "local",
                           "display_name": self.llamaState?.loadedModel ?? "Modelo cargado en el iPad",
                           "context_length": size, "supports_tools": self.llamaState?.supportsTools == true]]
            } else {
                models = []
            }
            self.sendResponse(connection: connection, status: "200 OK",
                              body: self.encode(["object": "list", "data": models]), contentType: "application/json")
        }
    }

    private func handleChatCompletion(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]], !messages.isEmpty else {
            sendError(connection, status: "400 Bad Request", message: "Expected text chat messages.")
            return
        }
        let textOnlyOpenCode = json["crucible_opencode_text"] as? Bool == true
        let worktreeHint = "When you create a worktree outside the current working directory and intend to use it as your primary working directory, consider using \u{0060}execute\u{0060} to call \u{0060}tools.opencode.session_move\u{0060} and make the worktree the session's working directory."
        let toolChat: ToolChat?
        let toolPrompt: String?
        let chat: [ChatMessage]
        do {
            let normalized = try messages.map { message in
                var message = message
                let role = message["role"] as? String == "developer" ? "system" : message["role"] as? String ?? ""
                var content = try ToolChat.content(message)
                // OpenCode appends the hint regardless of whether the client advertises execute.
                if textOnlyOpenCode, role == "system",
                   let hint = content.range(of: "\n" + worktreeHint, options: .backwards),
                   content[hint.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content.removeSubrange(hint.lowerBound...)
                }
                message["role"] = role
                message["content"] = content
                return message
            }
            toolChat = try ToolChat(json)
            if let toolChat {
                guard self.llamaState?.supportsTools == true else {
                    throw ToolChatError.request("Load a model with tool support, such as Qwen 3.5.")
                }
                toolPrompt = try toolChat.prompt(normalized)
                chat = []
            } else {
                toolPrompt = nil
                chat = try normalized.map { msg in
                    let role = msg["role"] as? String ?? ""
                    guard ["system", "user", "assistant"].contains(role),
                          (msg["tool_calls"] as? [[String: Any]] ?? []).isEmpty else {
                        throw ToolChatError.request("Unexpected role or tool calls in text chat.")
                    }
                    return ChatMessage(role: role, content: msg["content"] as? String ?? "")
                }
            }
        } catch {
            sendError(connection, status: "400 Bad Request", message: error.localizedDescription)
            return
        }

        let maxTokens = json["max_completion_tokens"] as? Int ?? json["max_tokens"] as? Int ?? (toolChat == nil ? 500 : 4096)
        guard maxTokens > 0 else {
            sendError(connection, status: "400 Bad Request", message: "max_tokens must be positive.")
            return
        }
        let stream = json["stream"] as? Bool == true
        let includeUsage = (json["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true
        let connectionID = ObjectIdentifier(connection)
        requests[connectionID] = Task { @MainActor in
            defer { self.requests.removeValue(forKey: connectionID) }
            guard let llamaState = self.llamaState else {
                connection.cancel()
                return
            }
            let metadata: [String: Any] = [
                "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
                "object": stream ? "chat.completion.chunk" : "chat.completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": "local"
            ]
            var started = false
            var result = ""
            var pendingText = ""
            var lastTextSend: UInt64?
            var textChunks = 0
            var output = ToolOutput(parseTools: toolChat != nil)
            func sendChunk(_ delta: [String: Any], finish: String? = nil) async throws {
                if !started {
                    started = true
                    try await self.send("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", to: connection)
                    let first = metadata.merging(["choices": [["index": 0, "delta": ["role": "assistant"], "finish_reason": NSNull()]]]) { _, new in new }
                    try await self.send("data: \(self.encode(first))\n\n", to: connection)
                }
                let reason: Any = finish.map { $0 as Any } ?? NSNull()
                let chunk = metadata.merging(["choices": [["index": 0, "delta": delta, "finish_reason": reason]]]) { _, new in new }
                try await self.send("data: \(self.encode(chunk))\n\n", to: connection)
            }
            do {
                func emit(_ text: String, final: Bool = false) async throws {
                    guard stream else {
                        result += text
                        return
                    }
                    pendingText += text
                    guard !pendingText.isEmpty else { return }
                    let now = DispatchTime.now().uptimeNanoseconds
                    let shouldFlush: Bool
                    if let lastTextSend {
                        shouldFlush = pendingText.utf8.count >= 64 || now - lastTextSend >= 45_000_000
                    } else {
                        shouldFlush = !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    guard final || shouldFlush else { return }
                    try await sendChunk(["content": pendingText])
                    pendingText = ""
                    lastTextSend = now
                    textChunks += 1
                }
                let usage = try await llamaState.generate(chat, maxTokens: maxTokens, fromServer: true, toolPrompt: toolPrompt) { piece in
                    try await emit(output.append(piece))
                }
                try await emit(output.append("", final: true), final: true)
                let calls = try toolChat?.calls(output.blocks) ?? []
                let finish = calls.isEmpty ? usage.finishReason : "tool_calls"
                let counts = ["prompt_tokens": usage.prompt, "completion_tokens": usage.output, "total_tokens": usage.prompt + usage.output]
                if stream {
                    if !calls.isEmpty {
                        try await sendChunk(["tool_calls": calls.enumerated().map { $0.element.json(index: $0.offset) }])
                    }
                    try await sendChunk([:], finish: finish)
                    if includeUsage {
                        let chunk = metadata.merging(["choices": [], "usage": counts]) { _, new in new }
                        try await self.send("data: \(self.encode(chunk))\n\n", to: connection)
                    }
                    try await self.send("data: [DONE]\n\n", to: connection)
                    DiagnosticLog.shared.write("Streaming: \(textChunks) bloques de texto para \(usage.output) tokens generados.", source: "API")
                    connection.cancel()
                } else {
                    var message: [String: Any] = ["role": "assistant", "content": result.trimmingCharacters(in: .whitespacesAndNewlines)]
                    if !calls.isEmpty {
                        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message["content"] = NSNull() }
                        message["tool_calls"] = calls.map { $0.json() }
                    }
                    let response = metadata.merging([
                        "choices": [["index": 0, "message": message, "finish_reason": finish]],
                        "usage": counts
                    ]) { _, new in new }
                    self.sendResponse(connection: connection, status: "200 OK", body: self.encode(response), contentType: "application/json")
                }
            } catch {
                let status: String
                let message: String
                switch error {
                case CompletionError.noModel:
                    (status, message) = ("503 Service Unavailable", "Load a model on the iPad.")
                case CompletionError.busy:
                    (status, message) = ("429 Too Many Requests", "The iPad is already running inference.")
                case is CancellationError:
                    (status, message) = ("409 Conflict", "Generation cancelled on the iPad.")
                case LlamaError.contextExceeded:
                    let size = llamaState.activeContextTokens.map(String.init) ?? "unknown"
                    (status, message) = ("400 Bad Request", "Prompt exceeds the \(size)-token context. Start a shorter session or load a larger context.")
                case LlamaError.invalidPrompt:
                    (status, message) = ("400 Bad Request", "Prompt is empty.")
                case LlamaError.decodeFailed:
                    (status, message) = ("500 Internal Server Error", "llama.cpp could not evaluate this model. Check Diagnostics on the iPad.")
                case let error as ToolChatError:
                    (status, message) = ("422 Unprocessable Content", error.localizedDescription)
                default:
                    (status, message) = ("500 Internal Server Error", "Generation failed.")
                }
                if started {
                    let error = self.encode(["error": ["message": message]])
                    try? await self.send("data: \(error)\n\n", to: connection)
                    connection.cancel()
                } else {
                    self.sendError(connection, status: status, message: message)
                }
            }
        }
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func send(_ text: String, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func sendError(_ connection: NWConnection, status: String, message: String) {
        DiagnosticLog.shared.write("\(status) · \(message)", source: "API")
        sendResponse(connection: connection, status: status,
                     body: encode(["error": ["message": message]]), contentType: "application/json")
    }

    private func sendResponse(connection: NWConnection, status: String, body: String,
                              contentType: String = "text/plain", extraHeaders: [String] = []) {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.utf8.count)\r\n"
        headers += "Access-Control-Allow-Origin: *\r\n"
        headers += "Connection: close\r\n"
        for header in extraHeaders {
            headers += "\(header)\r\n"
        }
        headers += "\r\n"

        let responseData = (headers + body).data(using: .utf8)!
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
