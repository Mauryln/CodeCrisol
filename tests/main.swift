import Foundation

let function: [String: Any] = [
    "name": "write",
    "parameters": [
        "type": "object", "required": ["path", "content", "overwrite"],
        "properties": ["path": ["type": "string"], "content": ["type": "string"], "overwrite": ["type": "boolean"]],
        "additionalProperties": false
    ]
]
let request: [String: Any] = ["tools": [["type": "function", "function": function]], "tool_choice": "required"]
let chat = try ToolChat(request)!
let firstPrompt = try chat.prompt([["role": "user", "content": "Create a file"]])
precondition(firstPrompt.contains("<tools>") && firstPrompt.contains("must call a tool"))
precondition(firstPrompt.hasSuffix("<|im_start|>assistant\n"))
precondition(ReasoningLevel.low.budget(forOutputLimit: 500) == 0)
precondition(ReasoningLevel.medium.budget(forOutputLimit: 500) == 128)
precondition(ReasoningLevel.high.budget(forOutputLimit: 4096) == 512)
precondition(ReasoningLevel.high.budget(forOutputLimit: 128) == 63)
precondition(ReasoningLevel.medium.budget(forOutputLimit: 32) == 0)

let sample = "<think>hidden</think>Done.\n<tool_call>\n<function=write>\n<parameter=path>\n001.html\n</parameter>\n<parameter=content>\n<h1>Hola</h1>\n\n</parameter>\n<parameter=overwrite>\nfalse\n</parameter>\n</function>\n</tool_call>"
var output = ToolOutput(parseTools: true)
var text = ""
for char in sample { text += try output.append(String(char)) }
text += try output.append("", final: true)
precondition(text == "Done.\n")
precondition(output.drainThinking().isEmpty)
var splitReasoning = ToolOutput(parseTools: false, captureThinking: true)
let opening = try splitReasoning.append("<thi")
precondition(opening.isEmpty && splitReasoning.drainThinking().isEmpty)
let hidden = try splitReasoning.append("nk>interno</thi")
precondition(hidden.isEmpty && splitReasoning.drainThinking() == "interno")
let answer = try splitReasoning.append("nk>respuesta")
precondition(answer == "respuesta" && splitReasoning.drainThinking().isEmpty)
var thoughtWithTool = ToolOutput(parseTools: true, captureThinking: true)
let hiddenTool = try thoughtWithTool.append("<think><tool_call>interno</tool_call></think>")
precondition(hiddenTool.isEmpty && thoughtWithTool.blocks.isEmpty)
precondition(thoughtWithTool.drainThinking() == "<tool_call>interno</tool_call>")
precondition(thoughtWithTool.drainThinking().isEmpty)
var duplicateReasoningClose = ToolOutput(parseTools: true, captureThinking: true)
let beforeDuplicate = try duplicateReasoningClose.append("<think>interno</think>Texto válido</thi")
let afterDuplicate = try duplicateReasoningClose.append("nk> y respuesta", final: true)
precondition(beforeDuplicate == "Texto válido" && afterDuplicate == " y respuesta")
precondition(duplicateReasoningClose.drainThinking() == "interno")
var toolWithCloseTag = ToolOutput(parseTools: true)
let embeddedClose = "<function=write>\n<parameter=content>\n</think>\n</parameter>\n</function>"
let toolWithCloseTagText = try toolWithCloseTag.append("<tool_call>\(embeddedClose)</tool_call>", final: true)
precondition(toolWithCloseTagText.isEmpty && toolWithCloseTag.blocks == [embeddedClose])
let calls = try chat.calls(output.blocks)
precondition(calls.count == 1 && calls[0].name == "write")
let arguments = try JSONSerialization.jsonObject(with: Data(calls[0].arguments.utf8)) as! [String: Any]
precondition(arguments["path"] as? String == "001.html")
precondition(arguments["content"] as? String == "<h1>Hola</h1>\n")
precondition(arguments["overwrite"] as? Bool == false)

let history: [[String: Any]] = [
    ["role": "user", "content": [["type": "text", "text": "Create a file"]]],
    ["role": "assistant", "content": NSNull(), "tool_calls": [calls[0].json()]],
    ["role": "tool", "tool_call_id": calls[0].id, "content": "File saved."]
]
let followUp = try chat.prompt(history)
precondition(followUp.contains("<tool_response>\nFile saved.\n</tool_response>"))
precondition(followUp.contains("<function=write>"))

do {
    _ = try chat.prompt(Array(history.dropLast()))
    fatalError("A missing tool result was accepted.")
} catch ToolChatError.request {}

do {
    _ = try chat.calls(["<function=unknown>\n</function>"])
    fatalError("An unknown tool was accepted.")
} catch ToolChatError.output {}

var incomplete = ToolOutput(parseTools: true)
do {
    _ = try incomplete.append("<tool_call><function=write>", final: true)
    fatalError("An incomplete tool call was accepted.")
} catch ToolChatError.output {}

let disabled = try ToolChat(["tools": request["tools"]!, "tool_choice": "none"])
precondition(disabled == nil)
let summary = try ToolChat(["messages": history, "tool_choice": "none"])!
let summaryPrompt = try summary.prompt(history)
precondition(summaryPrompt.contains("File saved.") && !summaryPrompt.contains("<tools>"))
print("Tool streaming, schemas and tool conversation history passed.")

func word(_ value: UInt32, big: Bool = false) -> Data {
    var ordered = big ? value.bigEndian : value.littleEndian
    return withUnsafeBytes(of: &ordered) { Data($0) }
}

func signedFixture(entitlement: [String: Any], slot: UInt32 = 5) throws -> Data {
    let plist = try PropertyListSerialization.data(fromPropertyList: entitlement, format: .xml, options: 0)
    let blob = word(0xfade7171, big: true) + word(UInt32(8 + plist.count), big: true) + plist
    let signature = word(0xfade0cc0, big: true) + word(UInt32(20 + blob.count), big: true)
        + word(1, big: true) + word(slot, big: true) + word(20, big: true) + blob
    let header = word(0xfeedfacf) + Data(repeating: 0, count: 12)
        + word(1) + word(16) + Data(repeating: 0, count: 8)
    return header + word(0x1d) + word(16) + word(48) + word(UInt32(signature.count)) + signature
}

let memoryKey = "com.apple.developer.kernel.increased-memory-limit"
let enabled = try signedFixture(entitlement: [memoryKey: true])
let off = try signedFixture(entitlement: [memoryKey: false])
let der = try signedFixture(entitlement: [:], slot: 7)
precondition(IncreasedMemoryStatus.read(enabled) == .enabled)
precondition(IncreasedMemoryStatus.read(off) == .disabled)
precondition(IncreasedMemoryStatus.read(der) == .unknown)
precondition(IncreasedMemoryStatus.read(Data(enabled.dropLast())) == .unknown)
print("Increased Memory Limit signature diagnostics passed.")
