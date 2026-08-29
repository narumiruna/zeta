import Foundation
import ZetaCore

public enum ProviderPayloadBuilder {
    public static func build(
        model: Model,
        context: Context,
        options: StreamOptions
    ) throws -> JSONValue {
        if let temperature = options.temperature, !temperature.isFinite {
            throw ProviderError.invalidResponse("Temperature must be finite")
        }
        switch model.api {
        case "anthropic-messages":
            return try anthropic(model: model, context: context, options: options)
        case "openai-responses", "azure-openai-responses", "openai-codex-responses":
            return try openAIResponses(model: model, context: context, options: options)
        case "google-generative-ai", "google-vertex":
            return try google(model: model, context: context, options: options)
        case "bedrock-converse-stream":
            return try bedrock(model: model, context: context, options: options)
        case "pi-messages":
            return try piMessages(model: model, context: context, options: options)
        default:
            return try openAICompletions(model: model, context: context, options: options)
        }
    }

    private static func openAICompletions(
        model: Model,
        context: Context,
        options: StreamOptions
    ) throws -> JSONValue {
        var messages: [JSONValue] = []
        if let system = context.systemPrompt {
            let role =
                model.compatibilityBool("supportsDeveloperRole") == true
                ? "developer" : "system"
            messages.append(["role": .string(role), "content": .string(system)])
        }
        messages += context.messages.map(openAIMessage)
        var object: OrderedJSONObject = [
            "model": .string(model.id),
            "messages": .array(messages),
            "stream": true,
        ]
        if model.compatibilityBool("supportsUsageInStreaming") != false {
            object["stream_options"] = ["include_usage": true]
        }
        if model.compatibilityBool("supportsStore") == true {
            object["store"] = false
        }
        try addCommonOptions(&object, model: model, options: options)
        addOpenAIThinking(&object, model: model, options: options)
        addOpenAITools(&object, model: model, context: context)
        return .object(object)
    }

    private static func openAIResponses(
        model: Model,
        context: Context,
        options: StreamOptions
    ) throws -> JSONValue {
        var input: [JSONValue] = context.messages.flatMap(responseItems)
        if let system = context.systemPrompt {
            let role =
                model.compatibilityBool("supportsDeveloperRole") != false
                ? "developer" : "system"
            input.insert(["role": .string(role), "content": .string(system)], at: 0)
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
            object["temperature"] = .number(try JSONNumber(temperature))
        }
        if let sessionID = options.sessionID {
            object["prompt_cache_key"] = .string(sessionID)
        }
        addOpenAIResponsesTools(&object, model: model, context: context)
        if let requested = options.thinking,
            let effort = model.requestThinkingValue(requested),
            requested != .off || model.thinkingLevelMapValue(.off) != nil
        {
            object["reasoning"] = ["effort": .string(effort)]
        }
        return .object(object)
    }

    private static func anthropic(
        model: Model,
        context: Context,
        options: StreamOptions
    ) throws -> JSONValue {
        var object: OrderedJSONObject = [
            "model": .string(model.id),
            "messages": .array(context.messages.map(anthropicMessage)),
            "max_tokens": .number(JSONNumber(options.maximumTokens ?? model.maximumTokens)),
            "stream": true,
        ]
        if let system = context.systemPrompt {
            object["system"] = .array([["type": "text", "text": .string(system)]])
        }
        if let temperature = options.temperature,
            model.compatibilityBool("supportsTemperature") != false
        {
            object["temperature"] = .number(try JSONNumber(temperature))
        }
        if let thinking = options.thinking, thinking != .off {
            let resolved = model.resolvedThinkingLevel(thinking)
            if model.compatibilityBool("forceAdaptiveThinking") == true {
                object["thinking"] = ["type": "adaptive"]
                if let effort = model.requestThinkingValue(resolved) {
                    object["output_config"] = ["effort": .string(effort)]
                }
            } else {
                object["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": .number(JSONNumber(max(1_024, thinkingBudget(resolved)))),
                ]
            }
        } else if options.thinking == .off, model.reasoning,
            model.thinkingLevelMapValue(.off) != .null
        {
            object["thinking"] = ["type": "disabled"]
        }
        if let tools = context.tools, !tools.isEmpty {
            object["tools"] = .array(
                tools.map { tool in
                    var value: OrderedJSONObject = [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "input_schema": tool.parameters,
                    ]
                    if model.compatibilityBool("supportsStrictTools") == true {
                        value["strict"] = true
                    }
                    return .object(value)
                })
        }
        return .object(object)
    }

    private static func google(
        model: Model,
        context: Context,
        options: StreamOptions
    ) throws -> JSONValue {
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
            generation["temperature"] = .number(try JSONNumber(temperature))
        }
        if let thinking = options.thinking, model.reasoning {
            let resolved = model.resolvedThinkingLevel(thinking)
            generation["thinkingConfig"] = [
                "includeThoughts": .bool(thinking != .off),
                "thinkingBudget": .number(JSONNumber(thinkingBudget(resolved))),
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
    ) throws -> JSONValue {
        var inference: OrderedJSONObject = [
            "maxTokens": .number(JSONNumber(options.maximumTokens ?? model.maximumTokens))
        ]
        if let temperature = options.temperature {
            inference["temperature"] = .number(try JSONNumber(temperature))
        }
        var object: OrderedJSONObject = [
            "messages": .array(bedrockMessages(context.messages)),
            "inferenceConfig": .object(inference),
        ]
        if let system = context.systemPrompt {
            object["system"] = .array([["text": .string(system)]])
        }
        if let tools = context.tools, !tools.isEmpty {
            object["toolConfig"] = [
                "tools": .array(
                    tools.map { tool in
                        var specification: OrderedJSONObject = [
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "inputSchema": ["json": tool.parameters],
                        ]
                        if model.compatibilityBool("supportsStrictMode") == true {
                            specification["strict"] = true
                        }
                        return ["toolSpec": .object(specification)]
                    }
                )
            ]
        }
        if let requested = options.thinking, requested != .off,
            model.reasoning,
            model.id.lowercased().contains("claude")
        {
            let resolved = model.resolvedThinkingLevel(requested)
            if bedrockUsesAdaptiveThinking(model) {
                object["additionalModelRequestFields"] = [
                    "thinking": ["type": "adaptive"],
                    "output_config": [
                        "effort": .string(model.requestThinkingValue(resolved) ?? resolved.rawValue)
                    ],
                ]
            } else {
                object["additionalModelRequestFields"] = [
                    "thinking": [
                        "type": "enabled",
                        "budget_tokens": .number(JSONNumber(bedrockThinkingBudget(resolved))),
                    ]
                ]
            }
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
            let output: JSONValue
            let content = result.content.map(responseInputContent)
            if content.contains(where: {
                if case .object(let value) = $0 { return value["type"] == "input_image" }
                return false
            }) {
                output = .array(content)
            } else {
                output = .string(text(from: result.content))
            }
            return [
                [
                    "type": "function_call_output",
                    "call_id": .string(result.toolCallId),
                    "output": output,
                ]
            ]
        case .user(let user):
            return [["role": "user", "content": .array(user.content.map(responseInputContent))]]
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

    private static func bedrockMessages(_ messages: [Message]) -> [JSONValue] {
        var output: [JSONValue] = []
        var index = 0
        while index < messages.count {
            switch messages[index] {
            case .user(let message):
                output.append([
                    "role": "user",
                    "content": .array(message.content.compactMap(bedrockContent)),
                ])
            case .assistant(let message):
                output.append([
                    "role": "assistant",
                    "content": .array(message.content.compactMap(bedrockContent)),
                ])
            case .toolResult:
                var results: [JSONValue] = []
                while index < messages.count,
                    case .toolResult(let result) = messages[index]
                {
                    results.append([
                        "toolResult": [
                            "toolUseId": .string(result.toolCallId),
                            "content": .array(result.content.compactMap(bedrockToolResultContent)),
                            "status": .string(result.isError ? "error" : "success"),
                        ]
                    ])
                    index += 1
                }
                output.append(["role": "user", "content": .array(results)])
                continue
            case .custom(let message):
                output.append([
                    "role": "user",
                    "content": .array([["text": .string(OrderedJSON.string(message.content))]]),
                ])
            }
            index += 1
        }
        return output
    }

    private static func bedrockContent(_ block: ContentBlock) -> JSONValue? {
        switch block {
        case .text(let text, _):
            return text.isEmpty ? nil : ["text": .string(text)]
        case .image(let data, let mime):
            return [
                "image": [
                    "format": .string(bedrockImageFormat(mime)),
                    "source": ["bytes": .string(data)],
                ]
            ]
        case .thinking(let text, let signature, let redacted):
            if redacted {
                guard let signature, !signature.isEmpty else { return nil }
                return ["reasoningContent": ["redactedContent": .string(signature)]]
            }
            guard !text.isEmpty else { return nil }
            if let signature, !signature.isEmpty {
                return [
                    "reasoningContent": [
                        "reasoningText": [
                            "text": .string(text),
                            "signature": .string(signature),
                        ]
                    ]
                ]
            }
            return ["text": .string(text)]
        case .toolCall(let call):
            return [
                "toolUse": [
                    "toolUseId": .string(call.id),
                    "name": .string(call.name),
                    "input": call.arguments,
                ]
            ]
        }
    }

    private static func bedrockToolResultContent(_ block: ContentBlock) -> JSONValue? {
        switch block {
        case .text(let text, _):
            return ["text": .string(text.isEmpty ? "<empty>" : text)]
        case .image(let data, let mime):
            return [
                "image": [
                    "format": .string(bedrockImageFormat(mime)),
                    "source": ["bytes": .string(data)],
                ]
            ]
        case .thinking, .toolCall:
            return nil
        }
    }

    private static func bedrockImageFormat(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": "jpeg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: mime.replacingOccurrences(of: "image/", with: "")
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

    private static func responseInputContent(_ block: ContentBlock) -> JSONValue {
        switch block {
        case .text(let text, _):
            ["type": "input_text", "text": .string(text)]
        case .image(let data, let mime):
            [
                "type": "input_image",
                "detail": "auto",
                "image_url": .string("data:\(mime);base64,\(data)"),
            ]
        case .thinking(let text, _, _):
            ["type": "input_text", "text": .string("<thinking>\(text)</thinking>")]
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
        model: Model,
        options: StreamOptions
    ) throws {
        if let temperature = options.temperature {
            object["temperature"] = .number(try JSONNumber(temperature))
        }
        if let maximum = options.maximumTokens {
            let field = model.compatibilityString("maxTokensField") ?? "max_completion_tokens"
            object[field] = .number(JSONNumber(maximum))
        }
    }

    private static func addOpenAIThinking(
        _ object: inout OrderedJSONObject,
        model: Model,
        options: StreamOptions
    ) {
        guard model.reasoning, let requested = options.thinking else { return }
        let enabled = requested != .off
        let effort = enabled ? model.requestThinkingValue(requested) : model.requestThinkingValue(.off)
        switch model.compatibilityString("thinkingFormat") ?? "openai" {
        case "openrouter":
            if let effort { object["reasoning"] = ["effort": .string(effort)] }
        case "deepseek", "zai":
            object["thinking"] = ["type": .string(enabled ? "enabled" : "disabled")]
            if enabled, model.compatibilityBool("supportsReasoningEffort") == true,
                let effort
            {
                object["reasoning_effort"] = .string(effort)
            }
        case "qwen":
            object["enable_thinking"] = .bool(enabled)
            if enabled, model.compatibilityBool("supportsReasoningEffort") == true,
                let effort
            {
                object["reasoning_effort"] = .string(effort)
            }
        case "qwen-chat-template":
            object["chat_template_kwargs"] = [
                "enable_thinking": .bool(enabled),
                "preserve_thinking": true,
            ]
        case "together":
            object["reasoning"] = ["enabled": .bool(enabled)]
            if enabled, model.compatibilityBool("supportsReasoningEffort") == true,
                let effort
            {
                object["reasoning_effort"] = .string(effort)
            }
        case "string-thinking":
            if let effort { object["thinking"] = .string(effort) }
        case "ant-ling":
            if enabled, let effort {
                object["reasoning"] = ["effort": .string(effort)]
            }
        default:
            if model.compatibilityBool("supportsReasoningEffort") == true,
                let effort
            {
                object["reasoning_effort"] = .string(effort)
            }
        }
    }

    private static func addOpenAITools(
        _ object: inout OrderedJSONObject,
        model: Model,
        context: Context
    ) {
        guard let tools = context.tools, !tools.isEmpty else { return }
        object["tools"] = .array(
            tools.map { tool in
                var function: OrderedJSONObject = [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters,
                ]
                if model.compatibilityBool("supportsStrictMode") == true {
                    function["strict"] = true
                }
                return [
                    "type": "function",
                    "function": .object(function),
                ]
            })
    }

    private static func addOpenAIResponsesTools(
        _ object: inout OrderedJSONObject,
        model: Model,
        context: Context
    ) {
        guard let tools = context.tools, !tools.isEmpty else { return }
        let supportsStrictMode = model.compatibilityBool("supportsStrictMode") ?? true
        object["tools"] = .array(
            tools.map { tool in
                var value: OrderedJSONObject = [
                    "type": "function",
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters,
                ]
                if supportsStrictMode { value["strict"] = true }
                return .object(value)
            }
        )
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

    private static func bedrockUsesAdaptiveThinking(_ model: Model) -> Bool {
        let value = "\(model.id) \(model.name)".lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return [
            "opus-4-6", "opus-4-7", "opus-4-8", "opus-5",
            "sonnet-4-6", "sonnet-5", "fable-5",
        ].contains { value.contains($0) }
    }

    private static func bedrockThinkingBudget(_ level: ThinkingLevel) -> Int {
        switch level {
        case .off: 0
        case .minimal: 1_024
        case .low: 2_048
        case .medium: 8_192
        case .high, .xhigh, .max: 16_384
        }
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
