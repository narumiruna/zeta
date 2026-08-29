import Foundation

public struct ValidationIssue: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case typeMismatch
        case missingProperty
        case unknownProperty
        case invalidValue
        case outOfRange
        case invalidFormat
        case noUnionMatch
        case ambiguousUnion
    }

    public let code: Code
    public let path: String
    public let message: String

    public init(code: Code, path: String = "$", message: String) {
        self.code = code
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

public struct ValidationFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let issues: [ValidationIssue]

    public init(_ issues: [ValidationIssue]) {
        precondition(!issues.isEmpty)
        self.issues = issues
    }

    public var description: String { issues.map(\.description).joined(separator: "\n") }
}

public enum ValidationMode: Sendable {
    case complete
    /// Missing required object properties are accepted, but every present value remains strict.
    case partial
}

public enum JSONSchemaAdditionalProperties: Sendable, Equatable {
    case allowed
    case forbidden
    indirect case schema(JSONSchema)
}

public struct JSONSchemaProperty: Sendable, Equatable {
    public let name: String
    public let schema: JSONSchema
    public let required: Bool

    public init(_ name: String, _ schema: JSONSchema, required: Bool = true) {
        self.name = name
        self.schema = schema
        self.required = required
    }
}

public indirect enum JSONSchema: Sendable, Equatable {
    case any
    case null
    case boolean
    case number(minimum: Double? = nil, maximum: Double? = nil)
    case integer(minimum: Int64? = nil, maximum: Int64? = nil, javascriptSafe: Bool = true)
    case string(minLength: Int? = nil, maxLength: Int? = nil, pattern: String? = nil)
    case array(items: JSONSchema, minItems: Int? = nil, maxItems: Int? = nil)
    case tuple(items: [JSONSchema], additionalItems: Bool = false)
    case object(properties: [JSONSchemaProperty], additionalProperties: JSONSchemaAdditionalProperties = .forbidden)
    case enumeration([JSONValue])
    case anyOf([JSONSchema])
    case oneOf([JSONSchema])
    case allOf([JSONSchema])

    public func validate(
        _ value: JSONValue,
        mode: ValidationMode = .complete,
        coerce: Bool = false
    ) throws -> JSONValue {
        do {
            return try validate(value, path: "$", mode: mode, coerce: coerce)
        } catch let issue as ValidationIssue {
            throw ValidationFailure([issue])
        }
    }

    public func accepts(_ value: JSONValue, mode: ValidationMode = .complete) -> Bool {
        (try? validate(value, path: "$", mode: mode, coerce: false)) != nil
    }

    private func validate(
        _ original: JSONValue,
        path: String,
        mode: ValidationMode,
        coerce: Bool
    ) throws -> JSONValue {
        switch self {
        case .any:
            return original
        case .null:
            if case .null = original { return original }
            if coerce {
                switch original {
                case .string(""):
                    return .null
                case .bool(false):
                    return .null
                case let .number(number) where number.doubleValue == 0:
                    return .null
                default:
                    break
                }
            }
            throw mismatch(path, expected: "null")
        case .boolean:
            if case .bool = original { return original }
            if coerce {
                switch original {
                case .null: return .bool(false)
                case .string("true"): return .bool(true)
                case .string("false"): return .bool(false)
                case let .number(number) where number.doubleValue == 1: return .bool(true)
                case let .number(number) where number.doubleValue == 0: return .bool(false)
                default: break
                }
            }
            throw mismatch(path, expected: "boolean")
        case let .number(minimum, maximum):
            let number = try coerceNumber(original, integer: false, enabled: coerce, path: path)
            guard number.doubleValue.isFinite else {
                throw ValidationIssue(code: .invalidValue, path: path, message: "Number must be finite")
            }
            try checkRange(number.doubleValue, minimum: minimum, maximum: maximum, path: path)
            return .number(number)
        case let .integer(minimum, maximum, javascriptSafe):
            let number = try coerceNumber(original, integer: true, enabled: coerce, path: path)
            let value: Int64
            if javascriptSafe {
                guard number.isInteger else { throw mismatch(path, expected: "integer") }
                guard number.isJavaScriptSafeInteger,
                    let safeValue = number.safeIntegerValue
                else {
                    throw ValidationIssue(
                        code: .outOfRange, path: path,
                        message: "Integer is outside the JavaScript-safe range")
                }
                value = safeValue
            } else {
                switch Self.preservedInteger(number.rawValue) {
                case .value(let preservedValue):
                    value = preservedValue
                case .notInteger:
                    throw mismatch(path, expected: "integer")
                case .outOfRange:
                    throw ValidationIssue(
                        code: .outOfRange, path: path,
                        message: "Integer is outside the supported range")
                }
            }
            if let minimum, value < minimum {
                throw ValidationIssue(code: .outOfRange, path: path, message: "Integer must be at least \(minimum)")
            }
            if let maximum, value > maximum {
                throw ValidationIssue(code: .outOfRange, path: path, message: "Integer must be at most \(maximum)")
            }
            return .number(number)
        case let .string(minLength, maxLength, pattern):
            let value: String
            switch original {
            case let .string(string): value = string
            case .null where coerce: value = ""
            case let .bool(boolean) where coerce: value = boolean ? "true" : "false"
            case let .number(number) where coerce: value = Self.javascriptNumberString(number)
            default: throw mismatch(path, expected: "string")
            }
            let length = value.unicodeScalars.count
            if let minLength, length < minLength {
                throw ValidationIssue(
                    code: .outOfRange, path: path, message: "String must contain at least \(minLength) Unicode scalars")
            }
            if let maxLength, length > maxLength {
                throw ValidationIssue(
                    code: .outOfRange, path: path, message: "String must contain at most \(maxLength) Unicode scalars")
            }
            if let pattern {
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                let expression: NSRegularExpression
                do { expression = try NSRegularExpression(pattern: pattern) } catch {
                    throw ValidationIssue(
                        code: .invalidFormat, path: path, message: "Schema contains an invalid regular expression")
                }
                if expression.firstMatch(in: value, range: range) == nil {
                    throw ValidationIssue(
                        code: .invalidFormat, path: path, message: "String does not match the required pattern")
                }
            }
            return .string(value)
        case let .array(items, minItems, maxItems):
            guard case let .array(values) = original else { throw mismatch(path, expected: "array") }
            try checkCount(values.count, minimum: minItems, maximum: maxItems, kind: "Array", path: path)
            return .array(
                try values.enumerated().map {
                    try items.validate($0.element, path: "\(path)[\($0.offset)]", mode: mode, coerce: coerce)
                })
        case let .tuple(items, additionalItems):
            guard case let .array(values) = original else { throw mismatch(path, expected: "array") }
            if !additionalItems, values.count > items.count {
                throw ValidationIssue(code: .invalidValue, path: path, message: "Tuple contains additional items")
            }
            if mode == .complete, values.count < items.count {
                throw ValidationIssue(code: .invalidValue, path: path, message: "Tuple is missing required items")
            }
            return .array(
                try values.enumerated().map { index, value in
                    guard index < items.count else { return value }
                    return try items[index].validate(value, path: "\(path)[\(index)]", mode: mode, coerce: coerce)
                })
        case let .object(properties, additionalProperties):
            guard case let .object(object) = original else { throw mismatch(path, expected: "object") }
            let propertyNames = Set(properties.map(\.name))
            var output = OrderedJSONObject()
            for property in properties {
                if let value = object[property.name] {
                    if case .null = value, !property.required, coerce, !property.schema.accepts(.null, mode: mode) {
                        continue
                    }
                    let validated = try property.schema.validate(
                        value,
                        path: Self.propertyPath(path, property.name),
                        mode: mode,
                        coerce: coerce
                    )
                    try output.append(key: property.name, value: validated)
                } else if property.required, mode == .complete {
                    throw ValidationIssue(
                        code: .missingProperty,
                        path: Self.propertyPath(path, property.name),
                        message: "Missing required property"
                    )
                }
            }
            for entry in object where !propertyNames.contains(entry.key) {
                let entryPath = Self.propertyPath(path, entry.key)
                switch additionalProperties {
                case .allowed:
                    try output.append(key: entry.key, value: entry.value)
                case .forbidden:
                    throw ValidationIssue(code: .unknownProperty, path: entryPath, message: "Unknown property")
                case let .schema(schema):
                    try output.append(
                        key: entry.key,
                        value: schema.validate(entry.value, path: entryPath, mode: mode, coerce: coerce)
                    )
                }
            }
            // Preserve caller field order while retaining schema-coerced values.
            var callerOrdered = OrderedJSONObject()
            for entry in object {
                if let value = output[entry.key] { try callerOrdered.append(key: entry.key, value: value) }
            }
            return .object(callerOrdered)
        case let .enumeration(values):
            guard values.contains(original) else {
                throw ValidationIssue(code: .invalidValue, path: path, message: "Value is not in the allowed set")
            }
            return original
        case let .anyOf(schemas):
            return try validateUnion(
                original, schemas: schemas, exactlyOne: false, path: path, mode: mode, coerce: coerce)
        case let .oneOf(schemas):
            return try validateUnion(
                original, schemas: schemas, exactlyOne: true, path: path, mode: mode, coerce: coerce)
        case let .allOf(schemas):
            var value = original
            for schema in schemas {
                value = try schema.validate(value, path: path, mode: mode, coerce: coerce)
            }
            return value
        }
    }

    private func validateUnion(
        _ value: JSONValue,
        schemas: [JSONSchema],
        exactlyOne: Bool,
        path: String,
        mode: ValidationMode,
        coerce: Bool
    ) throws -> JSONValue {
        var exact: [JSONValue] = []
        for schema in schemas {
            if let candidate = try? schema.validate(value, path: path, mode: mode, coerce: false) {
                exact.append(candidate)
            }
        }
        if exactlyOne, exact.count > 1 {
            throw ValidationIssue(
                code: .ambiguousUnion, path: path, message: "Value matches more than one union member")
        }
        if let first = exact.first { return first }
        if coerce {
            var coerced: [JSONValue] = []
            for schema in schemas {
                if let candidate = try? schema.validate(value, path: path, mode: mode, coerce: true) {
                    coerced.append(candidate)
                }
            }
            if exactlyOne, coerced.count > 1 {
                throw ValidationIssue(
                    code: .ambiguousUnion, path: path, message: "Coerced value matches more than one union member")
            }
            if let first = coerced.first { return first }
        }
        throw ValidationIssue(code: .noUnionMatch, path: path, message: "Value does not match any union member")
    }

    private func coerceNumber(
        _ original: JSONValue,
        integer: Bool,
        enabled: Bool,
        path: String
    ) throws -> JSONNumber {
        if case let .number(number) = original { return number }
        if enabled {
            switch original {
            case .null:
                return JSONNumber(0)
            case let .bool(boolean):
                return JSONNumber(boolean ? 1 : 0)
            case let .string(string) where !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                if let number = try? JSONNumber(validating: string), !integer || number.isInteger { return number }
            default:
                break
            }
        }
        throw mismatch(path, expected: integer ? "integer" : "number")
    }

    private enum PreservedInteger {
        case value(Int64)
        case notInteger
        case outOfRange
    }

    private static func preservedInteger(_ rawValue: String) -> PreservedInteger {
        var spelling = rawValue[...]
        let negative = spelling.first == "-"
        if negative { spelling.removeFirst() }

        let exponent: Int
        if let marker = spelling.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = boundedExponent(spelling[spelling.index(after: marker)...])
            spelling = spelling[..<marker]
        } else {
            exponent = 0
        }

        let fractionCount: Int
        var digits: String
        if let point = spelling.firstIndex(of: ".") {
            fractionCount = spelling.distance(from: spelling.index(after: point), to: spelling.endIndex)
            digits = String(spelling[..<point]) + String(spelling[spelling.index(after: point)...])
        } else {
            fractionCount = 0
            digits = String(spelling)
        }

        digits.removeFirst(digits.prefix(while: { $0 == "0" }).count)
        if digits.isEmpty { return .value(0) }

        let scale = exponent - fractionCount
        if scale < 0 {
            let removedCount = -scale
            guard removedCount <= digits.count,
                digits.suffix(removedCount).allSatisfy({ $0 == "0" })
            else {
                return .notInteger
            }
            digits.removeLast(removedCount)
            if digits.isEmpty { return .value(0) }
        } else if scale > 0 {
            guard digits.count + scale <= 19 else { return .outOfRange }
            digits.append(String(repeating: "0", count: scale))
        }

        guard digits.count <= 19 else { return .outOfRange }
        let maximum = negative ? "9223372036854775808" : "9223372036854775807"
        if digits.count == maximum.count, digits > maximum { return .outOfRange }
        guard let magnitude = UInt64(digits) else { return .outOfRange }
        if negative {
            if magnitude == UInt64(Int64.max) + 1 { return .value(Int64.min) }
            guard let value = Int64(exactly: magnitude) else { return .outOfRange }
            return .value(-value)
        }
        guard let value = Int64(exactly: magnitude) else { return .outOfRange }
        return .value(value)
    }

    private static func boundedExponent(_ spelling: Substring) -> Int {
        var value = 0
        var digits = spelling
        let negative = digits.first == "-"
        if digits.first == "-" || digits.first == "+" { digits.removeFirst() }
        for digit in digits {
            guard value < 10_000 else { return negative ? -10_000 : 10_000 }
            value = value * 10 + Int(String(digit))!
        }
        return negative ? -value : value
    }

    private func mismatch(_ path: String, expected: String) -> ValidationIssue {
        ValidationIssue(code: .typeMismatch, path: path, message: "Expected \(expected)")
    }

    private func checkRange(
        _ value: Double,
        minimum: Double?,
        maximum: Double?,
        path: String
    ) throws {
        if let minimum, value < minimum {
            throw ValidationIssue(code: .outOfRange, path: path, message: "Number must be at least \(minimum)")
        }
        if let maximum, value > maximum {
            throw ValidationIssue(code: .outOfRange, path: path, message: "Number must be at most \(maximum)")
        }
    }

    private func checkCount(
        _ count: Int,
        minimum: Int?,
        maximum: Int?,
        kind: String,
        path: String
    ) throws {
        if let minimum, count < minimum {
            throw ValidationIssue(
                code: .outOfRange, path: path, message: "\(kind) must contain at least \(minimum) items")
        }
        if let maximum, count > maximum {
            throw ValidationIssue(
                code: .outOfRange, path: path, message: "\(kind) must contain at most \(maximum) items")
        }
    }

    private static func propertyPath(_ path: String, _ name: String) -> String {
        if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { return "\(path).\(name)" }
        return "\(path)[\(OrderedJSON.string(.string(name)))]"
    }

    private static func javascriptNumberString(_ number: JSONNumber) -> String {
        if number.doubleValue == 0 { return "0" }
        if number.isInteger, let integer = number.safeIntegerValue { return String(integer) }
        return String(number.doubleValue)
    }
}

/// A small exact-object reader for hand-written discriminated wire decoders.
public struct StrictObjectReader: Sendable {
    public let object: OrderedJSONObject
    public let path: String
    private var consumed: Set<String> = []

    public init(_ value: JSONValue, path: String = "$") throws {
        guard case let .object(object) = value else {
            throw ValidationIssue(code: .typeMismatch, path: path, message: "Expected object")
        }
        self.object = object
        self.path = path
    }

    public mutating func required(_ key: String) throws -> JSONValue {
        consumed.insert(key)
        guard let value = object[key] else {
            throw ValidationIssue(code: .missingProperty, path: childPath(key), message: "Missing required property")
        }
        return value
    }

    public mutating func optional(_ key: String) -> JSONValue? {
        consumed.insert(key)
        return object[key]
    }

    public var remainingKeys: [String] {
        object.keys.filter { !consumed.contains($0) }
    }

    public func childPath(_ key: String) -> String {
        "\(path).\(key)"
    }

    public func finish() throws {
        if let unknown = object.first(where: { !consumed.contains($0.key) }) {
            throw ValidationIssue(code: .unknownProperty, path: childPath(unknown.key), message: "Unknown property")
        }
    }
}

public enum StrictValue {
    public static func string(_ value: JSONValue, path: String = "$", nonempty: Bool = false) throws -> String {
        guard case let .string(string) = value else {
            throw ValidationIssue(code: .typeMismatch, path: path, message: "Expected string")
        }
        if nonempty, string.isEmpty {
            throw ValidationIssue(code: .invalidValue, path: path, message: "String must not be empty")
        }
        return string
    }

    public static func boolean(_ value: JSONValue, path: String = "$") throws -> Bool {
        guard case let .bool(boolean) = value else {
            throw ValidationIssue(code: .typeMismatch, path: path, message: "Expected boolean")
        }
        return boolean
    }

    public static func finiteNumber(_ value: JSONValue, path: String = "$") throws -> Double {
        guard case let .number(number) = value, number.doubleValue.isFinite else {
            throw ValidationIssue(code: .typeMismatch, path: path, message: "Expected finite number")
        }
        return number.doubleValue
    }

    public static func safeInteger(
        _ value: JSONValue,
        path: String = "$",
        minimum: Int64? = nil,
        maximum: Int64? = nil
    ) throws -> Int64 {
        guard case let .number(number) = value, let integer = number.safeIntegerValue else {
            throw ValidationIssue(code: .typeMismatch, path: path, message: "Expected JavaScript-safe integer")
        }
        if let minimum, integer < minimum {
            throw ValidationIssue(code: .outOfRange, path: path, message: "Integer must be at least \(minimum)")
        }
        if let maximum, integer > maximum {
            throw ValidationIssue(code: .outOfRange, path: path, message: "Integer must be at most \(maximum)")
        }
        return integer
    }

    public static func array(_ value: JSONValue, path: String = "$") throws -> [JSONValue] {
        guard case let .array(array) = value else {
            throw ValidationIssue(code: .typeMismatch, path: path, message: "Expected array")
        }
        return array
    }
}
