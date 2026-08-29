import Foundation
import Testing

@testable import ZetaCore

@Suite struct ValidationTests {
    @Test func strictObjectUnionAndUnknownKeyValidation() throws {
        let schema = JSONSchema.object(properties: [
            .init("kind", .enumeration(["read", "write"])), .init("path", .string(minLength: 1)),
            .init("offset", .integer(minimum: 0), required: false),
            .init("metadata", .object(properties: [.init("enabled", .boolean, required: false)])),
        ])
        let value: JSONValue = ["kind": "read", "path": "file.txt", "offset": 2, "metadata": ["enabled": true]]
        #expect(try schema.validate(value) == value)
        expectValidationThrow { try schema.validate(["kind": "read", "path": "x", "metadata": [:], "extra": true]) }
        expectValidationThrow { try schema.validate(["kind": "other", "path": "x", "metadata": [:]]) }
    }

    @Test func ajvCompatiblePrimitiveCoercion() throws {
        let cases: [(JSONSchema, JSONValue, JSONValue)] = [
            (.number(), "42", 42), (.number(), true, 1), (.number(), nil, 0),
            (.integer(), "42", 42), (.boolean, "true", true), (.boolean, "false", false),
            (.boolean, 1, true), (.boolean, 0, false), (.string(), nil, ""),
            (.string(), true, "true"), (.null, "", nil), (.null, 0, nil), (.null, false, nil),
            (.anyOf([.number(), .string()]), "1", "1"), (.anyOf([.boolean, .number()]), "1", 1),
        ]
        for (schema, input, expected) in cases { #expect(try schema.validate(input, coerce: true) == expected) }
        for (schema, input) in [
            (JSONSchema.boolean, JSONValue.string("1")), (.boolean, .string("0")),
            (.null, .string("null")), (.integer(), .string("42.1")),
        ] { expectValidationThrow { try schema.validate(input, coerce: true) } }
    }

    @Test func optionalNullNormalizationAndNestedCoercion() throws {
        let schema = JSONSchema.object(properties: [
            .init("path", .string()), .init("offset", .number(), required: false),
            .init("nullable", .anyOf([.string(), .null]), required: false),
            .init("metadata", .object(properties: [.init("enabled", .boolean, required: false)])),
            .init("counts", .array(items: .integer())),
        ])
        let input: JSONValue = [
            "path": "file.txt", "offset": nil, "nullable": nil,
            "metadata": ["enabled": nil], "counts": ["1", true],
        ]
        #expect(
            try schema.validate(input, coerce: true) == [
                "path": "file.txt", "nullable": nil, "metadata": [:], "counts": [1, 1],
            ])
    }

    @Test func partialModeOnlyRelaxesMissingProperties() throws {
        let schema = JSONSchema.object(properties: [
            .init("required", .string(minLength: 1)), .init("count", .integer(minimum: 0)),
        ])
        #expect(try schema.validate(["required": "ok"], mode: .partial) == ["required": "ok"])
        expectValidationThrow { try schema.validate(["required": "ok"]) }
        expectValidationThrow { try schema.validate(["count": -1], mode: .partial) }
        expectValidationThrow { try schema.validate(["unknown": true], mode: .partial) }
    }

    @Test func integersBeyondJavaScriptSafeRangeUsePreservedSpelling() throws {
        let schema = JSONSchema.integer(javascriptSafe: false)
        for spelling in [
            "9007199254740993",
            "9007199254740993.0",
            "9.007199254740993e15",
            "9223372036854775807",
            "-9223372036854775808",
        ] {
            let value = try OrderedJSON.decode(spelling)
            let validated = try schema.validate(value)
            guard case .number(let number) = validated else {
                Issue.record("Expected integer for \(spelling)")
                continue
            }
            #expect(number.rawValue == spelling)
        }
    }

    @Test func preservedIntegersEnforceInt64AndSchemaBoundsExactly() throws {
        let bounded = JSONSchema.integer(
            minimum: 9_007_199_254_740_993,
            maximum: 9_007_199_254_740_994,
            javascriptSafe: false
        )
        #expect(
            try bounded.validate(OrderedJSON.decode("9007199254740993"))
                == OrderedJSON.decode("9007199254740993")
        )
        expectValidationThrow {
            try bounded.validate(OrderedJSON.decode("9007199254740992"))
        }
        expectValidationThrow {
            try bounded.validate(OrderedJSON.decode("9007199254740995"))
        }
        for spelling in [
            "9223372036854775808",
            "-9223372036854775809",
            "9007199254740993.5",
            "9.0071992547409935e15",
        ] {
            expectValidationThrow {
                try JSONSchema.integer(javascriptSafe: false).validate(
                    OrderedJSON.decode(spelling)
                )
            }
        }
        expectValidationThrow {
            try JSONSchema.integer().validate(
                OrderedJSON.decode("9007199254740993")
            )
        }
    }

    @Test func oneOfRejectsAmbiguousValues() {
        expectValidationThrow { try JSONSchema.oneOf([.number(), .integer()]).validate(1) }
    }

    @Test func strictReaderRejectsMissingAndUnknownFields() throws {
        var reader = try StrictObjectReader(["type": "known", "extra": true])
        #expect(try StrictValue.string(reader.required("type")) == "known")
        expectValidationThrow { try reader.finish() }
        var missing = try StrictObjectReader([:])
        expectValidationThrow { try missing.required("id") }
    }
}

private func expectValidationThrow<Value>(_ body: () throws -> Value) {
    do {
        _ = try body()
        Issue.record("Expected operation to throw")
    } catch {}
}
