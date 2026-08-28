import Foundation
import ZetaCore

public enum ProviderPayloadBuilder {
    public static func build(
        model: Model,
        context: Context,
        options: StreamOptions
    ) throws -> JSONValue {
        switch model.api {
        case "anthropic-messages":
            return anthropic(model: model, context: context, options: options)
        case "openai-responses", "azure-openai-responses", "openai-codex-responses":
            return openAIResponses(model: model, context: context, options: options)
        case "google-generative-ai", "google-vertex":
            return google(model: model, context: context, options: options)
        case "bedrock-converse-stream":
            return bedrock(model: model, context: context, options: options)
        case "pi-messages":
            return try piMessages(model: model, context: context, options: options)
        default:
            return openAICompletions(model: model, context: context, options: options)
        }
    }

    private static func openAICompletions(
        model: Model,
        context: Context,
        options: StreamOptions
    ) -> JSONValue {
        var messages: [JSONValue] = []
        if let system = context.systemPrompt {
            messages.append(["role": "system", "content": .string(system)])
        }
        messages += context.messages.map(openAIMessage)
        var object: OrderedJSONObject = [
            "model": .string(model.id),
            "messages": .array(messages),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        addCommonOptions(&object, options: options)
        addOpenAITools(&object, context: context)
        return .object(object)
    }

    private static func openAIResponses(
        model: Model,
        context: Context,
        options: StreamOptions
    ) -> JSONValue {
        var input: [JSONValue] = context.messages.flatMap(responseItems)
        if let system = context.systemPrompt {
            input.insert(["role": "developer", "content": .string(system)], at: 0)
        }
        var object: OrderedJSONObject = [
            "model": .string(model.id),
            "input": .array(input),
            "stream": true,
        ]
        if let maximum = options.maximumTokens {
            object["max_output_tokens"] = .number(JSONNumber(maximum))
        }
        if let temperature = options.temperature {
            object["temperature"] = .number(try! JSONNumber(temperature))
        }
        if let sessionID = options.sessionID {
            object["prompt_cache_key"] = .string(sessionID)
        }
        addOpenAITools(&object, context: context)
        return .object(object)
    }

    private static func anthropic(
        model: Model,
        context: Context,
        options: StreamOptions
    ) -> JSONValue {
        var object: OrderedJSONObject = [
            "model": .string(model.id),
            "messages": .array(context.messages.map(anthropicMessage)),
            "max_tokens": .number(JSONNumber(options.maximumTokens ?? model.maximumTokens)),
            "stream": true,
        ]
        if let system = context.systemPrompt {
            object["system"] = .array([["type": "text", "text": .string(system)]])
        }
        if let temperature = options.temperature {
            object["temperature"] = .number(try! JSONNumber(temperature))
        }
        if let thinking = options.thinking, thinking != .off {
            object["thinking"] = [
                "type": "enabled",
                "budget_tokens": .number(JSONNumber(thinkingBudget(thinking))),
            ]
        }
        if let tools = context.tools, !tools.isEmpty {
            object["tools"] = .array(
                tools.map { tool in
                    [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "input_schema": tool.parameters,
                    ]
                })
        }
        return .object(object)
    }

    private static func google(
        model: Model,
        context: Context,
        options: StreamOptions
    ) -> JSONValue {
        var object: OrderedJSONObject = [
            "contents": .array(context.messages.map(googleMessage))
        ]
        if let system = context.systemPrompt {
            object["systemInstruction"] = [
                "role": "user",
                "parts": .array([["text": .string(system)]]),
            ]
        }
        var generation: OrderedJSONObject = [:]
        if let maximum = options.maximumTokens {
            generation["maxOutputTokens"] = .number(JSONNumber(maximum))
        }
        if let temperature = options.temperature {
            generation["temperature"] = .number(try! JSONNumber(temperature))
        }
        if let thinking = options.thinking, thinking != .off {
            generation["thinkingConfig"] = [
                "thinkingBudget": .number(JSONNumber(thinkingBudget(thinking)))
            ]
        }
        if !generation.isEmpty {
            object["generationConfig"] = .object(generation)
        }
        if let tools = context.tools, !tools.isEmpty {
            object["tools"] = .array([
                [
                    "functionDeclarations": .array(
                        tools.map { tool in
                            [
                                "name": .string(tool.name),
                                "description": .string(tool.description),
                                "parameters": tool.parameters,
                            ]
                        })
                ]
            ])
        }
        return .object(object)
    }

    private static func bedrock(
        model: Model,
        context: Context,
        options: StreamOptions
    ) -> JSONValue {
        var object: OrderedJSONObject = [
            "messages": .array(context.messages.map(anthropicMessage)),
            "inferenceConfig": [
                "maxTokens": .number(JSONNumber(options.maximumTokens ?? model.maximumTokens))
            ],
        ]
        if let system = context.systemPrompt {
            object["system"] = .array([["text": .string(system)]])
        }
        return .object(object)
    }

    private static func piMessages(
        model: Model,
        context: Context,
        options: StreamOptions
    ) throws -> JSONValue {
        let contextValue = try OrderedJSON.decode(JSONEncoder().encode(context))
        var optionValues: OrderedJSONObject = [:]
        if let temperature = options.temperature {
            optionValues["temperature"] = .number(try JSONNumber(temperature))
        }
        if let maximum = options.maximumTokens {
            optionValues["maxTokens"] = .number(JSONNumber(maximum))
        }
        if let thinking = options.thinking {
            optionValues["reasoning"] = .string(thinking.rawValue)
        }
        if let sessionID = options.sessionID {
            optionValues["sessionId"] = .string(sessionID)
        }
        return [
            "model": .string(model.id),
            "context": contextValue,
            "options": .object(optionValues),
        ]
    }

    private static func openAIMessage(_ message: Message) -> JSONValue {
        switch message {
        case .user(let value):
            return ["role": "user", "content": .array(value.content.map(openAIContent))]
        case .assistant(let value):
            var object: OrderedJSONObject = [
                "role": "assistant",
                "content": .string(text(from: value.content)),
            ]
            let calls = value.content.compactMap { block -> JSONValue? in
                guard case .toolCall(let call) = block else { return nil }
                return [
                    "id": .string(call.id),
                    "type": "function",
                    "function": [
                        "name": .string(call.name),
                        "arguments": .string(OrderedJSON.string(call.arguments)),
                    ],
                ]
            }
            if !calls.isEmpty { object["tool_calls"] = .array(calls) }
            return .object(object)
        case .toolResult(let value):
            return [
                "role": "tool",
                "tool_call_id": .string(value.toolCallId),
                "content": .string(text(from: value.content)),
            ]
        case .custom(let value):
            return [
                "role": "user",
                "content": .string(OrderedJSON.string(value.content)),
            ]
        }
    }

    private static func responseItems(_ message: Message) -> [JSONValue] {
        switch message {
        case .assistant(let assistant):
            var output: [JSONValue] = []
            let content = text(from: assistant.content)
            if !content.isEmpty {
                output.append(["role": "assistant", "content": .string(content)])
            }
            output += assistant.content.compactMap { block in
                guard case .toolCall(let call) = block else { return nil }
                return [
                    "type": "function_call",
                    "call_id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": .string(OrderedJSON.string(call.arguments)),
                ]
            }
            return output
        case .toolResult(let result):
            return [
                [
                    "type": "function_call_output",
                    "call_id": .string(result.toolCallId),
                    "output": .string(text(from: result.content)),
                ]
            ]
        case .user(let user):
            return [["role": "user", "content": .array(user.content.map(openAIContent))]]
        case .custom(let value):
            return [
                [
                    "role": "user",
                    "content": .string(OrderedJSON.string(value.content)),
                ]
            ]
        }
    }

    private static func anthropicMessage(_ message: Message) -> JSONValue {
        switch message {
        case .user(let value):
            return ["role": "user", "content": .array(value.content.map(anthropicContent))]
        case .assistant(let value):
            return ["role": "assistant", "content": .array(value.content.map(anthropicContent))]
        case .toolResult(let value):
            return [
                "role": "user",
                "content": .array([
                    [
                        "type": "tool_result",
                        "tool_use_id": .string(value.toolCallId),
                        "content": .string(text(from: value.content)),
                        "is_error": .bool(value.isError),
                    ]
                ]),
            ]
        case .custom(let value):
            return [
                "role": "user",
                "content": .array([
                    [
                        "type": "text",
                        "text": .string(OrderedJSON.string(value.content)),
                    ]
                ]),
            ]
        }
    }

    private static func googleMessage(_ message: Message) -> JSONValue {
        switch message {
        case .user(let value):
            return ["role": "user", "parts": .array(value.content.map(googleContent))]
        case .assistant(let value):
            return ["role": "model", "parts": .array(value.content.map(googleContent))]
        case .toolResult(let value):
            return [
                "role": "user",
                "parts": .array([
                    [
                        "functionResponse": [
                            "name": .string(value.toolName),
                            "response": ["result": .string(text(from: value.content))],
                        ]
                    ]
                ]),
            ]
        case .custom(let value):
            return [
                "role": "user",
                "parts": .array([
                    [
                        "text": .string(OrderedJSON.string(value.content))
                    ]
                ]),
            ]
        }
    }

    private static func openAIContent(_ block: ContentBlock) -> JSONValue {
        switch block {
        case .text(let text, _):
            ["type": "text", "text": .string(text)]
        case .image(let data, let mime):
            ["type": "image_url", "image_url": ["url": .string("data:\(mime);base64,\(data)")]]
        case .thinking(let text, _, _):
            ["type": "text", "text": .string("<thinking>\(text)</thinking>")]
        case .toolCall:
            .null
        }
    }

    private static func anthropicContent(_ block: ContentBlock) -> JSONValue {
        switch block {
        case .text(let text, _):
            ["type": "text", "text": .string(text)]
        case .thinking(let text, let signature, let redacted):
            redacted
                ? ["type": "redacted_thinking", "data": .string(signature ?? "")]
                : [
                    "type": "thinking",
                    "thinking": .string(text),
                    "signature": .string(signature ?? ""),
                ]
        case .image(let data, let mime):
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": .string(mime),
                    "data": .string(data),
                ],
            ]
        case .toolCall(let call):
            [
                "type": "tool_use",
                "id": .string(call.id),
                "name": .string(call.name),
                "input": call.arguments,
            ]
        }
    }

    private static func googleContent(_ block: ContentBlock) -> JSONValue {
        switch block {
        case .text(let text, _):
            ["text": .string(text)]
        case .thinking(let text, let signature, _):
            ["text": .string(text), "thought": true, "thoughtSignature": .string(signature ?? "")]
        case .image(let data, let mime):
            ["inlineData": ["mimeType": .string(mime), "data": .string(data)]]
        case .toolCall(let call):
            ["functionCall": ["name": .string(call.name), "args": call.arguments]]
        }
    }

    private static func addCommonOptions(
        _ object: inout OrderedJSONObject,
        options: StreamOptions
    ) {
        if let temperature = options.temperature {
            object["temperature"] = .number(try! JSONNumber(temperature))
        }
        if let maximum = options.maximumTokens {
            object["max_completion_tokens"] = .number(JSONNumber(maximum))
        }
    }

    private static func addOpenAITools(
        _ object: inout OrderedJSONObject,
        context: Context
    ) {
        guard let tools = context.tools, !tools.isEmpty else { return }
        object["tools"] = .array(
            tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters,
                    ],
                ]
            })
    }

    private static func text(from blocks: [ContentBlock]) -> String {
        blocks.compactMap { block in
            switch block {
            case .text(let text, _): text
            case .thinking(let text, _, _): "<thinking>\(text)</thinking>"
            default: nil
            }
        }.joined(separator: "\n")
    }

    private static func thinkingBudget(_ level: ThinkingLevel) -> Int {
        switch level {
        case .off: 0
        case .minimal: 128
        case .low: 512
        case .medium: 1_024
        case .high: 4_096
        case .xhigh: 16_384
        case .max: 32_768
        }
    }
}

private extension OrderedJSONObject {
    var isEmpty: Bool { startIndex == endIndex }
}
