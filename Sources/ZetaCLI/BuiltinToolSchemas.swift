import ZetaCore

enum BuiltinToolSchemas {
    private static let string = JSONSchema.string()
    private static let editItem = JSONSchema.object(
        properties: [
            JSONSchemaProperty("oldText", string),
            JSONSchemaProperty("newText", string),
        ]
    )

    static let values: [String: JSONSchema] = [
        "read": .object(properties: [JSONSchemaProperty("path", string)]),
        "write": .object(
            properties: [
                JSONSchemaProperty("path", string),
                JSONSchemaProperty("content", string),
            ]
        ),
        "edit": .object(
            properties: [
                JSONSchemaProperty("path", string),
                JSONSchemaProperty("edits", .array(items: editItem, minItems: 1)),
            ]
        ),
        "bash": .object(properties: [JSONSchemaProperty("command", string)]),
        "grep": .object(properties: [JSONSchemaProperty("pattern", string)]),
        "find": .object(properties: [JSONSchemaProperty("pattern", string)]),
        "ls": .object(
            properties: [JSONSchemaProperty("path", string, required: false)]
        ),
    ]

    static func schema(for name: String) -> JSONSchema {
        precondition(values[name] != nil, "Unknown built-in tool schema: \(name)")
        return values[name]!
    }

    static func definitionParameters(for name: String) -> JSONValue {
        switch name {
        case "read":
            object(properties: ["path": stringProperty], required: ["path"])
        case "write":
            object(
                properties: ["path": stringProperty, "content": stringProperty],
                required: ["path", "content"]
            )
        case "edit":
            object(
                properties: [
                    "path": stringProperty,
                    "edits": [
                        "type": "array",
                        "items": object(
                            properties: ["oldText": stringProperty, "newText": stringProperty],
                            required: ["oldText", "newText"]
                        ),
                        "minItems": 1,
                    ],
                ],
                required: ["path", "edits"]
            )
        case "bash":
            object(properties: ["command": stringProperty], required: ["command"])
        case "grep", "find":
            object(properties: ["pattern": stringProperty], required: ["pattern"])
        case "ls":
            object(properties: ["path": stringProperty], required: [])
        default:
            preconditionFailure("Unknown built-in tool schema: \(name)")
        }
    }

    private static var stringProperty: JSONValue { ["type": "string"] }

    private static func object(
        properties: OrderedJSONObject,
        required: [String]
    ) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }
}
