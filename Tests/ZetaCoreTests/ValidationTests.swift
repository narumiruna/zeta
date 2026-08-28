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
