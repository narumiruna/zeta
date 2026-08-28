import Foundation
import Testing

@testable import ZetaTelemetry

@Suite struct TelemetrySchemaTests {
    @Test func schemaMetadataIsSerializableAndValidated() throws {
        let definition = TelemetrySchemaDefinition(
            version: 1,
            spans: [
                "operation": .init(
                    description: "Test operation", parents: .any,
                    startAttributes: [
                        "kind": .init(
                            type: .string, description: "Kind", required: true,
                            allowedValues: [.string("read"), .string("write")]
                        )
                    ],
                    endAttributes: ["count": .init(type: .number, description: "Count")],
                    events: [
                        "result": .init(
                            description: "Result",
                            attributes: ["outcome": .init(type: .string, description: "Outcome", required: true)]
                        )
                    ],
                    errorWhen: "The operation fails"
                )
            ]
        )
        #expect(defineTelemetrySchema(definition) == definition)
        try TelemetrySchemaValidator.validate(definition)
        #expect(
            try JSONDecoder().decode(TelemetrySchemaDefinition.self, from: JSONEncoder().encode(definition))
                == definition)
        try TelemetrySchemaValidator.validateAttributes(
            ["kind": "read"], definitions: definition.spans["operation"]!.startAttributes)
        expectSchemaThrow {
            try TelemetrySchemaValidator.validateAttributes(
                [:], definitions: definition.spans["operation"]!.startAttributes)
        }
        expectSchemaThrow {
            try TelemetrySchemaValidator.validateAttributes(
                ["kind": "other"], definitions: definition.spans["operation"]!.startAttributes)
        }
        expectSchemaThrow {
            try TelemetrySchemaValidator.validateAttributes(
                ["unknown": true], definitions: definition.spans["operation"]!.startAttributes)
        }
    }

    @Test func rejectsInconsistentMetadata() {
        let definition = TelemetrySchemaDefinition(
            version: 1,
            spans: [
                "bad": .init(
                    description: "Bad", parents: .spans([]),
                    startAttributes: [
                        "value": .init(type: .number, description: "Value", allowedValues: [.string("wrong")])
                    ],
                    errorWhen: "Bad"
                )
            ]
        )
        expectSchemaThrow { try TelemetrySchemaValidator.validate(definition) }
    }

    @Test func allAttributeKindsRoundTrip() throws {
        let values: [TelemetryAttributeValue] = [
            .string("text"), .number(1.5), .boolean(true),
            .strings(["a", "b"]), .numbers([1, 2]), .booleans([true, false]),
        ]
        for value in values {
            #expect(try JSONDecoder().decode(TelemetryAttributeValue.self, from: JSONEncoder().encode(value)) == value)
        }
    }
}

private func expectSchemaThrow<Value>(_ body: () throws -> Value) {
    do {
        _ = try body()
        Issue.record("Expected operation to throw")
    } catch {}
}
