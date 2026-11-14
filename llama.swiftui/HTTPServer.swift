import Foundation
import Network

/// Minimal HTTP server that serves an OpenAI-compatible chat completions API
class HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    private weak var llamaState: LlamaState?

    var isRunning: Bool { listener != nil }

    init(port: UInt16 = 8080) {
        self.port = port
    }

    func start(llamaState: LlamaState) throws {
        self.llamaState = llamaState
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.stateUpdateHandler = { [weak llamaState] state in
            if case .failed(let error) = state {
                Task { @MainActor in llamaState?.serverFailed(error) }
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))
        print("HTTP Server started on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        print("HTTP Server stopped")
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
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, finished, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
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
            let models: [[String: Any]] = self.llamaState?.hasModel == true
                ? [["id": "local", "object": "model", "created": 0, "owned_by": "local"]] : []
            self.sendResponse(connection: connection, status: "200 OK",
                              body: self.encode(["object": "list", "data": models]), contentType: "application/json")
        }
    }

    private func handleChatCompletion(body: Data, connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]], !messages.isEmpty,
              messages.allSatisfy({ message in
                  guard let role = message["role"] as? String else { return false }
                  return ["system", "developer", "user", "assistant"].contains(role)
                      && message["content"] is String && message["tool_calls"] == nil
              }) else {
            sendError(connection, status: "400 Bad Request", message: "Expected text chat messages.")
            return
        }
        let toolChoice = json["tool_choice"] as? String
        // OpenCode may send optional tool declarations even for text-only models.
        guard json["tool_choice"] == nil || toolChoice == "auto" || toolChoice == "none" else {
            sendError(connection, status: "400 Bad Request", message: "This server cannot execute required tool calls.")
            return
        }

        // ChatML for the Qwen models used by the OpenCode setup.
        var prompt = ""
        let hasSystemMessage = messages.contains { ($0["role"] as? String) == "system" }
        if !hasSystemMessage {
            prompt += "<|im_start|>system\n/no_think\nBe concise and helpful.<|im_end|>\n"
        }
        for msg in messages {
            let role = msg["role"] as? String == "developer" ? "system" : msg["role"] as? String ?? "user"
            let content = msg["content"] as? String ?? ""
            prompt += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"

        let maxTokens = json["max_completion_tokens"] as? Int ?? json["max_tokens"] as? Int ?? 500
        guard maxTokens > 0 else {
            sendError(connection, status: "400 Bad Request", message: "max_tokens must be positive.")
            return
        }
        let stream = json["stream"] as? Bool == true
        let includeUsage = (json["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true
        Task { @MainActor in
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
                let usage = try await llamaState.generate(text: prompt, maxTokens: maxTokens, parseSpecial: true, fromServer: true) { piece in
                    if stream {
                        try await sendChunk(["content": piece])
                    } else {
                        result += piece
                    }
                }
                let counts = ["prompt_tokens": usage.prompt, "completion_tokens": usage.output, "total_tokens": usage.prompt + usage.output]
                if stream {
                    try await sendChunk([:], finish: usage.finishReason)
                    if includeUsage {
                        let chunk = metadata.merging(["choices": [], "usage": counts]) { _, new in new }
                        try await self.send("data: \(self.encode(chunk))\n\n", to: connection)
                    }
                    try await self.send("data: [DONE]\n\n", to: connection)
                    connection.cancel()
                } else {
                    if let start = result.range(of: "<think>") {
                        if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                            result = String(result[end.upperBound...])
                        } else {
                            result = String(result[..<start.lowerBound])
                        }
                    }
                    if let end = result.range(of: "<|im_end|>") {
                        result = String(result[..<end.lowerBound])
                    }
                    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let response = metadata.merging([
                        "choices": [["index": 0, "message": ["role": "assistant", "content": result], "finish_reason": usage.finishReason]],
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
                case LlamaError.contextExceeded, LlamaError.invalidPrompt:
                    (status, message) = ("400 Bad Request", "Prompt is empty or exceeds the 4096-token context. Start a shorter session.")
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
