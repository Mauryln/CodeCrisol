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

let sample = "<think>hidden</think>Done.\n<tool_call>\n<function=write>\n<parameter=path>\n001.html\n</parameter>\n<parameter=content>\n<h1>Hola</h1>\n\n</parameter>\n<parameter=overwrite>\nfalse\n</parameter>\n</function>\n</tool_call>"
var output = ToolOutput(parseTools: true)
var text = ""
for char in sample { text += try output.append(String(char)) }
text += try output.append("", final: true)
precondition(text == "Done.\n")
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
print("Tool streaming, schemas and tool conversation history passed.")
