import Foundation

enum ReasoningLevel: Int, CaseIterable {
    case low, medium, high

    var title: String {
        switch self {
        case .low: return "Bajo"
        case .medium: return "Medio"
        case .high: return "Alto"
        }
    }

    var maximumTokens: Int {
        switch self {
        case .low: return 0
        case .medium: return 128
        case .high: return 512
        }
    }

    func budget(forOutputLimit limit: Int) -> Int {
        // Keep room for an answer or a tool call, even in a short response.
        min(maximumTokens, max(0, limit - max(64, limit / 2) - 1))
    }
}

enum ToolChatError: LocalizedError {
    case request(String)
    case output(String)

    var errorDescription: String? {
        switch self {
        case .request(let message), .output(let message): return message
        }
    }
}

struct ToolCall {
    let id: String
    let name: String
    let arguments: String

    func json(index: Int? = nil) -> [String: Any] {
        var fields: [String: Any] = [
            "id": id, "type": "function", "function": ["name": name, "arguments": arguments]
        ]
        if let index { fields["index"] = index }
        return fields
    }
}

struct ToolChat {
    private let definitions: [String: [String: Any]]
    private let required: Bool
    private let parallel: Bool

    init?(_ request: [String: Any]) throws {
        let choice = request["tool_choice"]
        let hasHistory = (request["messages"] as? [[String: Any]] ?? []).contains {
            $0["role"] as? String == "tool" || !($0["tool_calls"] as? [[String: Any]] ?? []).isEmpty
        }
        if choice as? String == "none" {
            if !hasHistory { return nil }
            definitions = [:]
            required = false
            parallel = true
            return
        }
        let tools = request["tools"] as? [[String: Any]] ?? []
        if tools.isEmpty, choice == nil || choice as? String == "auto" {
            if !hasHistory { return nil }
            definitions = [:]
            required = false
            parallel = true
            return
        }
        var name: String?
        if let selection = choice as? [String: Any],
           selection["type"] as? String == "function",
           let function = selection["function"] as? [String: Any] {
            name = function["name"] as? String
        }
        guard choice == nil || choice as? String == "auto" || choice as? String == "required" || name != nil else {
            throw ToolChatError.request("Unsupported tool_choice.")
        }
        var schemas: [String: [String: Any]] = [:]
        for tool in tools {
            guard tool["type"] as? String == "function",
                  let function = tool["function"] as? [String: Any],
                  let key = function["name"] as? String, Self.validName(key),
                  schemas.updateValue(function, forKey: key) == nil else {
                throw ToolChatError.request("Expected unique function tool definitions.")
            }
        }
        if let name { schemas = schemas.filter { $0.key == name } }
        guard !schemas.isEmpty else { throw ToolChatError.request("The selected tool is missing.") }
        definitions = schemas
        required = name != nil || choice as? String == "required"
        parallel = request["parallel_tool_calls"] as? Bool ?? true
    }

    static func content(_ message: [String: Any]) throws -> String {
        guard let raw = message["content"], !(raw is NSNull) else { return "" }
        if let text = raw as? String { return text }
        if let parts = raw as? [[String: Any]], parts.allSatisfy({
            $0["type"] as? String == "text" && $0["text"] is String
        }) {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        throw ToolChatError.request("Expected text message content.")
    }

    func prompt(_ messages: [[String: Any]]) throws -> String {
        let tools = try definitions.keys.sorted().compactMap { definitions[$0] }.map {
            try Self.encode(["type": "function", "function": $0])
        }.joined(separator: "\n")
        let instructions = """
        # Tools
        <tools>
        \(tools)
        </tools>

        To call a function, use this format. Supply all required parameters and do not claim success until you receive a tool result.
        <tool_call>
        <function=example>
        <parameter=argument>
        value
        </parameter>
        </function>
        </tool_call>
        """
        var systems = [definitions.isEmpty ? "Use the existing tool results to answer. No new tools are available on this turn." : instructions]
        if required { systems.append("You must call a tool on this turn.") }
        if !parallel { systems.append("Call at most one tool per turn.") }
        var turns = ""
        var pendingIDs: Set<String> = []
        var toolResponses = false
        for message in messages {
            let role = message["role"] as? String ?? ""
            let content = Self.escaped(try Self.content(message))
            if toolResponses && role != "tool" {
                turns += "<|im_end|>\n"
                toolResponses = false
            }
            switch role {
            case "system", "developer":
                systems.append(content)
            case "user":
                guard pendingIDs.isEmpty else { throw ToolChatError.request("Tool results are missing.") }
                turns += "<|im_start|>user\n\(content)<|im_end|>\n"
            case "assistant":
                guard pendingIDs.isEmpty else { throw ToolChatError.request("Tool results are missing.") }
                turns += "<|im_start|>assistant\n" + content
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let id = call["id"] as? String, pendingIDs.insert(id).inserted,
                          let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String, Self.validName(name),
                          let raw = function["arguments"] as? String,
                          let args = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                        throw ToolChatError.request("Malformed assistant tool call in history.")
                    }
                    turns += "\n<tool_call>\n<function=\(name)>\n"
                    for key in args.keys.sorted() {
                        guard Self.validName(key), let value = args[key] else {
                            throw ToolChatError.request("Invalid tool argument in history.")
                        }
                        let text = try value as? String ?? Self.encode(value)
                        turns += "<parameter=\(key)>\n\(Self.escaped(text))\n</parameter>\n"
                    }
                    turns += "</function>\n</tool_call>"
                }
                turns += "<|im_end|>\n"
            case "tool":
                guard let id = message["tool_call_id"] as? String, pendingIDs.remove(id) != nil else {
                    throw ToolChatError.request("Unexpected tool result ID.")
                }
                if !toolResponses { turns += "<|im_start|>user"; toolResponses = true }
                turns += "\n<tool_response>\n\(content)\n</tool_response>"
            default:
                throw ToolChatError.request("Unsupported role in tool conversation.")
            }
        }
        guard pendingIDs.isEmpty else { throw ToolChatError.request("Tool results are missing.") }
        if toolResponses { turns += "<|im_end|>\n" }
        return "<|im_start|>system\n\(systems.joined(separator: "\n\n"))<|im_end|>\n"
            + turns + "<|im_start|>assistant\n"
    }

    func calls(_ blocks: [String]) throws -> [ToolCall] {
        if blocks.isEmpty, required { throw ToolChatError.output("The model did not return the requested tool call.") }
        guard parallel || blocks.count <= 1 else { throw ToolChatError.output("The model returned multiple tool calls.") }
        return try blocks.map { block in
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard lines.hasPrefix("<function="), let end = lines.firstIndex(of: ">"),
                  let close = lines.range(of: "</function>", options: .backwards),
                  end < close.lowerBound,
                  lines[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolChatError.output("The model returned invalid tool markup.")
            }
            let name = String(lines[lines.index(lines.startIndex, offsetBy: 10)..<end])
            guard let schema = definitions[name] else { throw ToolChatError.output("The model requested an unknown tool.") }
            let parameters = schema["parameters"] as? [String: Any] ?? [:]
            let properties = parameters["properties"] as? [String: [String: Any]] ?? [:]
            let requiredKeys = parameters["required"] as? [String] ?? []
            var args: [String: Any] = [:]
            var remainder = lines[lines.index(after: end)..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            while !remainder.isEmpty {
                guard remainder.hasPrefix("<parameter="), let split = remainder.firstIndex(of: ">"),
                      let stop = remainder.range(of: "</parameter>"), split < stop.lowerBound else {
                    throw ToolChatError.output("The model returned an invalid tool parameter.")
                }
                let key = String(remainder[remainder.index(remainder.startIndex, offsetBy: 11)..<split])
                guard Self.validName(key), args[key] == nil,
                      properties.isEmpty || properties[key] != nil || parameters["additionalProperties"] as? Bool != false else {
                    throw ToolChatError.output("The model returned an unexpected tool parameter.")
                }
                var value = String(remainder[remainder.index(after: split)..<stop.lowerBound])
                if value.hasPrefix("\n") { value.removeFirst() }
                if value.hasSuffix("\n") { value.removeLast() }
                if properties[key]?["type"] as? String == "string" {
                    args[key] = value
                } else {
                    args[key] = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) ?? value
                }
                remainder = remainder[stop.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard requiredKeys.allSatisfy({ args[$0] != nil }) else {
                throw ToolChatError.output("The model omitted a required tool argument.")
            }
            return ToolCall(id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), name: name, arguments: try Self.encode(args))
        }
    }

    private static func validName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "<|im_", with: "<\u{200B}|im_")
            .replacingOccurrences(of: "</parameter>", with: "</\u{200B}parameter>")
            .replacingOccurrences(of: "</tool_response>", with: "</\u{200B}tool_response>")
    }

    private static func encode(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

struct ToolOutput {
    private enum Mode { case text, thinking, tool }
    private var mode = Mode.text
    private var buffer = ""
    private var block = ""
    private var thinking = ""
    private(set) var blocks: [String] = []
    let parseTools: Bool
    private let captureThinking: Bool

    init(parseTools: Bool, captureThinking: Bool = false) {
        self.parseTools = parseTools
        self.captureThinking = captureThinking
    }

    mutating func drainThinking() -> String {
        let captured = thinking
        thinking = ""
        return captured
    }

    mutating func append(_ piece: String, final: Bool = false) throws -> String {
        buffer += piece
        var visible = ""
        while !buffer.isEmpty {
            let markers: [String]
            switch mode {
            case .text: markers = parseTools ? ["<think>", "<tool_call>"] : ["<think>"]
            case .thinking: markers = ["</think>"]
            case .tool: markers = ["</tool_call>"]
            }
            if let tag = markers.compactMap({ marker in buffer.range(of: marker).map { (marker, $0) } })
                .min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
                consume(String(buffer[..<tag.1.lowerBound]), visible: &visible)
                buffer.removeSubrange(..<tag.1.upperBound)
                switch tag.0 {
                case "<think>": mode = .thinking
                case "<tool_call>": mode = .tool
                case "</tool_call>": blocks.append(block); block = ""; mode = .text
                default: mode = .text
                }
            } else {
                let retained = final ? 0 : markers.map { marker in
                    (1..<marker.count).reversed().first { buffer.hasSuffix(String(marker.prefix($0))) } ?? 0
                }.max() ?? 0
                let end = buffer.index(buffer.endIndex, offsetBy: -retained)
                consume(String(buffer[..<end]), visible: &visible)
                buffer.removeSubrange(..<end)
                break
            }
        }
        if final, mode == .tool { throw ToolChatError.output("The model returned an incomplete tool call.") }
        return visible
    }

    private mutating func consume(_ text: String, visible: inout String) {
        switch mode {
        case .text: visible += text
        case .tool: block += text
        case .thinking:
            if captureThinking { thinking += text }
        }
    }
}
