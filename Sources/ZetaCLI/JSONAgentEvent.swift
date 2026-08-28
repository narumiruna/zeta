import Foundation
import ZetaAI
import ZetaAgent
import ZetaCore

struct JSONAgentEvent: Encodable {
    let value: JSONValue

    init(_ event: AgentEvent) {
        switch event {
        case .agentStart:
            value = ["type": "agent_start"]
        case .agentEnd(let messages):
            value = [
                "type": "agent_end",
                "messages": .array(messages.map(Self.json)),
            ]
        case .turnStart:
            value = ["type": "turn_start"]
        case .turnEnd(let message, let toolResults):
            value = [
                "type": "turn_end",
                "message": Self.json(message),
                "toolResults": .array(toolResults.map(Self.json)),
            ]
        case .messageStart(let message):
            value = [
                "type": "message_start",
                "message": Self.json(message),
            ]
        case .messageUpdate(_, let update):
            value = [
                "type": "message_update",
                "assistantMessageEvent": Self.update(update),
            ]
        case .messageEnd(let message):
            value = [
                "type": "message_end",
                "message": Self.json(message),
            ]
        case .toolExecutionStart(let id, let name, let arguments):
            value = [
                "type": "tool_execution_start",
                "toolCallId": .string(id),
                "toolName": .string(name),
                "args": arguments,
            ]
        case .toolExecutionUpdate(let id, let name, let result):
            value = [
                "type": "tool_execution_update",
                "toolCallId": .string(id),
                "toolName": .string(name),
                "content": .array(result.content.map(Self.json)),
                "details": result.details ?? .null,
            ]
        case .toolExecutionEnd(let id, let name, let result, let isError):
            value = [
                "type": "tool_execution_end",
                "toolCallId": .string(id),
                "toolName": .string(name),
                "content": .array(result.content.map(Self.json)),
                "details": result.details ?? .null,
                "isError": .bool(isError),
            ]
        }
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    private static func json<T: Encodable>(_ value: T) -> JSONValue {
        (try? OrderedJSON.decode(JSONEncoder().encode(value))) ?? .null
    }

    private static func update(_ event: AssistantEvent) -> JSONValue {
        switch event {
        case .start:
            return ["type": "start"]
        case .textStart(let index, _):
            return ["type": "text_start", "contentIndex": .number(JSONNumber(index))]
        case .textDelta(let index, let delta, _):
            return [
                "type": "text_delta",
                "contentIndex": .number(JSONNumber(index)),
                "delta": .string(delta),
            ]
        case .textEnd(let index, let content, _):
            return [
                "type": "text_end",
                "contentIndex": .number(JSONNumber(index)),
                "content": .string(content),
            ]
        case .thinkingStart(let index, _):
            return ["type": "thinking_start", "contentIndex": .number(JSONNumber(index))]
        case .thinkingDelta(let index, let delta, _):
            return [
                "type": "thinking_delta",
                "contentIndex": .number(JSONNumber(index)),
                "delta": .string(delta),
            ]
        case .thinkingEnd(let index, let content, _):
            return [
                "type": "thinking_end",
                "contentIndex": .number(JSONNumber(index)),
                "content": .string(content),
            ]
        case .toolCallStart(let index, let partial):
            let call =
                partial.content.indices.contains(index)
                ? partial.content[index] : nil
            let id: String
            let name: String
            if case .toolCall(let value)? = call {
                id = value.id
                name = value.name
            } else {
                id = ""
                name = ""
            }
            return [
                "type": "toolcall_start",
                "contentIndex": .number(JSONNumber(index)),
                "id": .string(id),
                "toolName": .string(name),
            ]
        case .toolCallDelta(let index, let delta, _):
            return [
                "type": "toolcall_delta",
                "contentIndex": .number(JSONNumber(index)),
                "delta": .string(delta),
            ]
        case .toolCallEnd(let index, let call, _):
            return [
                "type": "toolcall_end",
                "contentIndex": .number(JSONNumber(index)),
                "toolCall": json(call),
            ]
        case .done(let reason, let message):
            return [
                "type": "done",
                "reason": .string(reason.rawValue),
                "usage": json(message.usage),
            ]
        case .error(let reason, let message):
            return [
                "type": "error",
                "reason": .string(reason.rawValue),
                "errorMessage": .string(message.errorMessage ?? ""),
                "usage": json(message.usage),
            ]
        }
    }
}
