import Foundation

public enum TelemetryAttributeType: String, Codable, Sendable, CaseIterable {
    case string
    case number
    case boolean
    case stringArray = "string[]"
    case numberArray = "number[]"
    case booleanArray = "boolean[]"

    public func accepts(_ value: TelemetryAttributeValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.number, .number), (.boolean, .boolean),
            (.stringArray, .strings), (.numberArray, .numbers), (.booleanArray, .booleans):
            true
        default:
            false
        }
    }
}

public enum TelemetryCardinality: String, Codable, Sendable {
    case low
    case high
}

public struct TelemetryAttributeDefinition: Codable, Sendable, Equatable {
    public let type: TelemetryAttributeType
    public let description: String
    public let required: Bool
    public let sensitive: Bool?
    public let cardinality: TelemetryCardinality?
    public let allowedValues: [TelemetryAttributeValue]?
    public let examples: [TelemetryAttributeValue]?

    public init(
        type: TelemetryAttributeType,
        description: String,
        required: Bool = false,
        sensitive: Bool? = nil,
        cardinality: TelemetryCardinality? = nil,
        allowedValues: [TelemetryAttributeValue]? = nil,
        examples: [TelemetryAttributeValue]? = nil
    ) {
        self.type = type
        self.description = description
        self.required = required
        self.sensitive = sensitive
        self.cardinality = cardinality
        self.allowedValues = allowedValues
        self.examples = examples
    }

    public func accepts(_ value: TelemetryAttributeValue) -> Bool {
        type.accepts(value) && (allowedValues?.contains(value) ?? true)
    }
}

public struct TelemetryEventDefinition: Codable, Sendable, Equatable {
    public let description: String
    public let attributes: [String: TelemetryAttributeDefinition]

    public init(description: String, attributes: [String: TelemetryAttributeDefinition] = [:]) {
        self.description = description
        self.attributes = attributes
    }
}

public enum TelemetryParentDefinition: Sendable, Equatable, Codable {
    case any
    case rootOrExternal
    case spans([String])

    private enum CodingKeys: String, CodingKey { case kind, spans }
    private enum Kind: String, Codable {
        case any
        case rootOrExternal = "root_or_external"
        case spans
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .any: self = .any
        case .rootOrExternal: self = .rootOrExternal
        case .spans: self = .spans(try container.decode([String].self, forKey: .spans))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .any: try container.encode(Kind.any, forKey: .kind)
        case .rootOrExternal: try container.encode(Kind.rootOrExternal, forKey: .kind)
        case let .spans(spans):
            try container.encode(Kind.spans, forKey: .kind)
            try container.encode(spans, forKey: .spans)
        }
    }
}

public struct TelemetrySpanDefinition: Codable, Sendable, Equatable {
    public let description: String
    public let parents: TelemetryParentDefinition
    public let startAttributes: [String: TelemetryAttributeDefinition]
    public let endAttributes: [String: TelemetryAttributeDefinition]
    public let events: [String: TelemetryEventDefinition]?
    public let errorWhen: String

    public init(
        description: String,
        parents: TelemetryParentDefinition,
        startAttributes: [String: TelemetryAttributeDefinition] = [:],
        endAttributes: [String: TelemetryAttributeDefinition] = [:],
        events: [String: TelemetryEventDefinition]? = nil,
        errorWhen: String
    ) {
        self.description = description
        self.parents = parents
        self.startAttributes = startAttributes
        self.endAttributes = endAttributes
        self.events = events
        self.errorWhen = errorWhen
    }
}

public struct TelemetrySchemaDefinition: Codable, Sendable, Equatable {
    public let version: Int
    public let spans: [String: TelemetrySpanDefinition]

    public init(version: Int, spans: [String: TelemetrySpanDefinition]) {
        self.version = version
        self.spans = spans
    }
}

public struct TelemetrySchemaError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

public enum TelemetrySchemaValidator {
    public static func validate(_ schema: TelemetrySchemaDefinition) throws {
        guard schema.version >= 0 else { throw TelemetrySchemaError("Telemetry schema version must be nonnegative") }
        for (spanName, span) in schema.spans {
            guard !spanName.isEmpty else { throw TelemetrySchemaError("Telemetry span names must not be empty") }
            try validateDefinitions(span.startAttributes, owner: "span \(spanName) start")
            try validateDefinitions(span.endAttributes, owner: "span \(spanName) end", permitRequired: false)
            if case let .spans(parents) = span.parents {
                guard !parents.isEmpty, parents.allSatisfy({ !$0.isEmpty }) else {
                    throw TelemetrySchemaError("Span \(spanName) must declare nonempty parent span names")
                }
            }
            for (eventName, event) in span.events ?? [:] {
                guard !eventName.isEmpty else { throw TelemetrySchemaError("Telemetry event names must not be empty") }
                try validateDefinitions(event.attributes, owner: "event \(eventName)")
            }
        }
    }

    public static func validateAttributes(
        _ attributes: SpanAttributes,
        definitions: [String: TelemetryAttributeDefinition],
        requireRequired: Bool = true
    ) throws {
        if requireRequired {
            for (name, definition) in definitions where definition.required && attributes[name] == nil {
                throw TelemetrySchemaError("Missing required telemetry attribute \(name)")
            }
        }
        for (name, value) in attributes {
            guard let definition = definitions[name] else {
                throw TelemetrySchemaError("Unknown telemetry attribute \(name)")
            }
            guard definition.accepts(value) else {
                throw TelemetrySchemaError("Telemetry attribute \(name) has an invalid value")
            }
        }
    }

    private static func validateDefinitions(
        _ definitions: [String: TelemetryAttributeDefinition],
        owner: String,
        permitRequired: Bool = true
    ) throws {
        for (name, definition) in definitions {
            guard !name.isEmpty else { throw TelemetrySchemaError("\(owner) contains an empty attribute name") }
            if !permitRequired, definition.required {
                throw TelemetrySchemaError("\(owner) attributes cannot be required")
            }
            for value in (definition.allowedValues ?? []) + (definition.examples ?? [])
            where !definition.type.accepts(value) {
                throw TelemetrySchemaError("\(owner) attribute \(name) metadata does not match its type")
            }
        }
    }
}

/// Identity helper mirroring Pi's serializable schema declaration API.
public func defineTelemetrySchema(_ schema: TelemetrySchemaDefinition) -> TelemetrySchemaDefinition { schema }
