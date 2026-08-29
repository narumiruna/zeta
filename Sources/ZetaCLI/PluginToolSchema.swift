import Foundation
import ZetaCore

struct PluginToolSchema: Sendable {
    let definition: JSONValue
    let validator: JSONSchema

    init(data: Data) throws {
        do {
            definition = try OrderedJSON.decode(data)
            validator = try PluginJSONSchemaDecoder.decode(definition)
        } catch let error as PluginToolSchemaError {
            throw error
        } catch {
            throw PluginToolSchemaError.invalid("Schema is not valid JSON: \(error)")
        }
    }
}

enum PluginToolSchemaError: Error, LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): "Invalid plugin tool schema: \(message)"
        }
    }
}

private enum PluginJSONSchemaDecoder {
    private static let annotationKeywords: Set<String> = [
        "$comment", "$id", "$schema", "default", "description", "examples", "title",
    ]

    static func decode(_ value: JSONValue, path: String = "$schema") throws -> JSONSchema {
        guard case .object(let object) = value else {
            throw invalid(path, "must be an object")
        }
        try validateAnnotations(object, path: path)
        let semanticKeys = Set(object.keys).subtracting(annotationKeywords)
        if semanticKeys.isEmpty { return .any }

        if let enumeration = object["enum"] {
            try requireOnly(semanticKeys, allowed: ["enum", "type"], path: path)
            guard case .array(let values) = enumeration, !values.isEmpty else {
                throw invalid("\(path).enum", "must be a non-empty array")
            }
            let schema = JSONSchema.enumeration(values)
            guard object["type"] != nil else { return schema }
            var typedObject = object
            typedObject["enum"] = nil
            return .allOf([try decodeType(typedObject, path: path), schema])
        }
        if let constant = object["const"] {
            try requireOnly(semanticKeys, allowed: ["const", "type"], path: path)
            let schema = JSONSchema.enumeration([constant])
            guard object["type"] != nil else { return schema }
            var typedObject = object
            typedObject["const"] = nil
            return .allOf([try decodeType(typedObject, path: path), schema])
        }
        for (keyword, constructor) in [
            ("anyOf", JSONSchema.anyOf),
            ("oneOf", JSONSchema.oneOf),
            ("allOf", JSONSchema.allOf),
        ] {
            if let value = object[keyword] {
                try requireOnly(semanticKeys, allowed: [keyword], path: path)
                guard case .array(let values) = value, !values.isEmpty else {
                    throw invalid("\(path).\(keyword)", "must be a non-empty array")
                }
                return constructor(
                    try values.enumerated().map {
                        try decode($0.element, path: "\(path).\(keyword)[\($0.offset)]")
                    }
                )
            }
        }
        return try decodeType(object, path: path)
    }

    private static func decodeType(
        _ object: OrderedJSONObject,
        path: String
    ) throws -> JSONSchema {
        guard case .string(let type)? = object["type"] else {
            throw invalid(path, "must contain a supported type, enum, const, or composition keyword")
        }
        switch type {
        case "null":
            try requireOnly(Set(object.keys).subtracting(annotationKeywords), allowed: ["type"], path: path)
            return .null
        case "boolean":
            try requireOnly(Set(object.keys).subtracting(annotationKeywords), allowed: ["type"], path: path)
            return .boolean
        case "number":
            try requireOnly(
                Set(object.keys).subtracting(annotationKeywords),
                allowed: ["type", "minimum", "maximum"],
                path: path
            )
            let minimum = try optionalDouble(object["minimum"], path: "\(path).minimum")
            let maximum = try optionalDouble(object["maximum"], path: "\(path).maximum")
            try validateRange(minimum: minimum, maximum: maximum, path: path)
            return .number(minimum: minimum, maximum: maximum)
        case "integer":
            try requireOnly(
                Set(object.keys).subtracting(annotationKeywords),
                allowed: ["type", "minimum", "maximum"],
                path: path
            )
            let minimum = try optionalInt64(object["minimum"], path: "\(path).minimum")
            let maximum = try optionalInt64(object["maximum"], path: "\(path).maximum")
            try validateRange(minimum: minimum, maximum: maximum, path: path)
            return .integer(minimum: minimum, maximum: maximum)
        case "string":
            try requireOnly(
                Set(object.keys).subtracting(annotationKeywords),
                allowed: ["type", "minLength", "maxLength", "pattern"],
                path: path
            )
            let minimum = try optionalNonnegativeInt(object["minLength"], path: "\(path).minLength")
            let maximum = try optionalNonnegativeInt(object["maxLength"], path: "\(path).maxLength")
            try validateRange(minimum: minimum, maximum: maximum, path: path)
            let pattern = try optionalString(object["pattern"], path: "\(path).pattern")
            if let pattern {
                do {
                    _ = try NSRegularExpression(pattern: pattern)
                } catch {
                    throw invalid("\(path).pattern", "must be a valid regular expression")
                }
            }
            return .string(minLength: minimum, maxLength: maximum, pattern: pattern)
        case "array":
            return try decodeArray(object, path: path)
        case "object":
            return try decodeObject(object, path: path)
        default:
            throw invalid("\(path).type", "contains unsupported type \"\(type)\"")
        }
    }

    private static func decodeArray(
        _ object: OrderedJSONObject,
        path: String
    ) throws -> JSONSchema {
        let semanticKeys = Set(object.keys).subtracting(annotationKeywords)
        guard let items = object["items"] else {
            try requireOnly(
                semanticKeys,
                allowed: ["type", "minItems", "maxItems"],
                path: path
            )
            let minimum = try optionalNonnegativeInt(object["minItems"], path: "\(path).minItems")
            let maximum = try optionalNonnegativeInt(object["maxItems"], path: "\(path).maxItems")
            try validateRange(minimum: minimum, maximum: maximum, path: path)
            return .array(items: .any, minItems: minimum, maxItems: maximum)
        }
        if case .array = items {
            throw invalid("\(path).items", "tuple schemas are unsupported")
        }
        try requireOnly(
            semanticKeys,
            allowed: ["type", "items", "minItems", "maxItems"],
            path: path
        )
        let minimum = try optionalNonnegativeInt(object["minItems"], path: "\(path).minItems")
        let maximum = try optionalNonnegativeInt(object["maxItems"], path: "\(path).maxItems")
        try validateRange(minimum: minimum, maximum: maximum, path: path)
        return .array(
            items: try decode(items, path: "\(path).items"),
            minItems: minimum,
            maxItems: maximum
        )
    }

    private static func decodeObject(
        _ object: OrderedJSONObject,
        path: String
    ) throws -> JSONSchema {
        let semanticKeys = Set(object.keys).subtracting(annotationKeywords)
        try requireOnly(
            semanticKeys,
            allowed: ["type", "properties", "required", "additionalProperties"],
            path: path
        )
        let rawProperties: OrderedJSONObject
        if let value = object["properties"] {
            guard case .object(let properties) = value else {
                throw invalid("\(path).properties", "must be an object")
            }
            rawProperties = properties
        } else {
            rawProperties = [:]
        }
        let required = try requiredNames(object["required"], properties: rawProperties, path: path)
        let properties = try rawProperties.map { entry in
            JSONSchemaProperty(
                entry.key,
                try decode(entry.value, path: "\(path).properties.\(entry.key)"),
                required: required.contains(entry.key)
            )
        }
        let additionalProperties: JSONSchemaAdditionalProperties
        switch object["additionalProperties"] {
        case nil, .bool(true)?:
            additionalProperties = .allowed
        case .bool(false)?:
            additionalProperties = .forbidden
        case .object(let schemaObject)?:
            additionalProperties = .schema(
                try decode(.object(schemaObject), path: "\(path).additionalProperties")
            )
        default:
            throw invalid("\(path).additionalProperties", "must be a boolean or schema object")
        }
        return .object(properties: properties, additionalProperties: additionalProperties)
    }

    private static func requiredNames(
        _ value: JSONValue?,
        properties: OrderedJSONObject,
        path: String
    ) throws -> Set<String> {
        guard let value else { return [] }
        guard case .array(let values) = value else {
            throw invalid("\(path).required", "must be an array of property names")
        }
        var names = Set<String>()
        for (index, value) in values.enumerated() {
            guard case .string(let name) = value, properties[name] != nil,
                names.insert(name).inserted
            else {
                throw invalid(
                    "\(path).required[\(index)]",
                    "must be a unique name declared in properties"
                )
            }
        }
        return names
    }

    private static func validateAnnotations(
        _ object: OrderedJSONObject,
        path: String
    ) throws {
        for keyword in ["$comment", "$id", "$schema", "description", "title"] {
            if object[keyword] != nil {
                _ = try optionalString(object[keyword], path: "\(path).\(keyword)")
            }
        }
        if let examples = object["examples"], case .array = examples {
        } else if object["examples"] != nil {
            throw invalid("\(path).examples", "must be an array")
        }
    }

    private static func requireOnly(
        _ actual: Set<String>,
        allowed: Set<String>,
        path: String
    ) throws {
        if let keyword = actual.subtracting(allowed).sorted().first {
            throw invalid("\(path).\(keyword)", "is unsupported")
        }
    }

    private static func optionalString(
        _ value: JSONValue?,
        path: String
    ) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else { throw invalid(path, "must be a string") }
        return string
    }

    private static func optionalDouble(
        _ value: JSONValue?,
        path: String
    ) throws -> Double? {
        guard let value else { return nil }
        guard case .number(let number) = value else { throw invalid(path, "must be a number") }
        return number.doubleValue
    }

    private static func optionalInt64(
        _ value: JSONValue?,
        path: String
    ) throws -> Int64? {
        guard let value else { return nil }
        guard case .number(let number) = value, let integer = number.safeIntegerValue else {
            throw invalid(path, "must be a JavaScript-safe integer")
        }
        return integer
    }

    private static func optionalNonnegativeInt(
        _ value: JSONValue?,
        path: String
    ) throws -> Int? {
        guard let integer = try optionalInt64(value, path: path) else { return nil }
        guard integer >= 0, integer <= Int.max else {
            throw invalid(path, "must be a nonnegative integer")
        }
        return Int(integer)
    }

    private static func validateRange<T: Comparable>(
        minimum: T?,
        maximum: T?,
        path: String
    ) throws {
        if let minimum, let maximum, minimum > maximum {
            throw invalid(path, "has a minimum greater than its maximum")
        }
    }

    private static func invalid(_ path: String, _ message: String) -> PluginToolSchemaError {
        .invalid("\(path) \(message)")
    }
}
