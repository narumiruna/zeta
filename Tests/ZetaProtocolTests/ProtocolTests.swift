import Foundation
import Testing
import ZetaCore

@testable import ZetaProtocol

@Suite struct ProtocolTests {
    private var emptySnapshot: ServerSnapshot {
        get throws { try ServerSnapshot(serverID: "server-1", revision: 0, sessions: [], models: []) }
    }

    @Test func versionNegotiationAndStrictHello() throws {
        #expect(protocolVersion == 1)
        #expect(isSupportedProtocolVersion(1))
        #expect(!isSupportedProtocolVersion(2))
        for version in [0, 1, 2] {
            let source = "{\"type\":\"hello\",\"version\":\(version)}"
            #expect(try parseClientMessage(j(source)) == .hello(ClientHello(version: Int64(version))))
        }
        for source in [
            #"{"type":"hello","version":"1"}"#, #"{"type":"hello","version":1.5}"#,
            #"{"type":"hello","version":1,"token":"secret"}"#, #"{"type":"hello","version":1,"extra":true}"#,
        ] { expectProtocolThrow { try parseClientMessage(j(source)) } }
    }

    @Test func byteExactClientHello() throws {
        #expect(
            try encodeClientMessage(.hello(ClientHello())).hex == "00000015a264747970656568656c6c6f6776657273696f6e01")
    }

    @Test func serverHelloRoundTrip() throws {
        let message = ServerMessage.hello(try ServerHello(connectionID: "connection-1", snapshot: emptySnapshot))
        #expect(try parseServerMessage(message.protocolJSONValue()) == message)
        let decoder = try ServerMessageDecoder()
        #expect(try decoder.push(encodeServerMessage(message)) == [message])
        try decoder.end()
    }

    @Test func listedSessionsAreStrictDurableMetadata() throws {
        let valid = j(
            #"{"type":"response","id":"request-1","ok":true,"result":{"command":"list","sessions":[{"id":"session-1","createdAt":1,"updatedAt":2,"parentSessionId":"parent-1","sessionName":"Named session","cwd":"/workspace"}]}}"#
        )
        _ = try parseServerMessage(valid)
        expectProtocolThrow {
            try parseServerMessage(
                j(
                    #"{"type":"response","id":"request-1","ok":true,"result":{"command":"list","sessions":[{"id":"session-1","createdAt":1,"phase":"idle"}]}}"#
                ))
        }
    }

    @Test func protocolErrorCodesAndJSONDetails() throws {
        for code in ["not_implemented", "internal_error"] {
            _ = try parseServerMessage(
                j(
                    """
                      {"type":"response","id":"request-1","ok":false,
                       "error":{"code":"\(code)","message":"safe"}}
                    """))
        }
        _ = try parseServerMessage(
            j(
                #"{"type":"response","id":"request-1","ok":false,"error":{"code":"invalid_request","message":"invalid","details":{"lines":[1,2,3],"cached":false}}}"#
            ))
    }

    @Test func rejectsInvalidServerUnions() throws {
        let snapshot = try emptySnapshot.protocolJSONValue()
        let invalid: [JSONValue] = [
            object([("type", "hello"), ("version", 2), ("connectionId", "connection-1"), ("snapshot", snapshot)]),
            j(#"{"type":"hello_error","error":{"code":"auth","message":"failed"}}"#),
            j(#"{"type":"response","id":"r","ok":true,"result":{"command":"unknown"}}"#),
            j(#"{"type":"event","event":{"type":"session_removed","sessionId":42}}"#),
        ]
        for value in invalid { expectProtocolThrow { try parseServerMessage(value) } }
    }

    @Test func assistantStateInvariants() {
        let valid = [
            #""status":"streaming""#, #""status":"complete","stopReason":"stop""#,
            #""status":"error","stopReason":"error""#,
            #""status":"error","stopReason":"error","errorMessage":"failed""#,
            #""status":"aborted","stopReason":"aborted""#,
        ]
        for state in valid {
            let progress = state.contains("streaming") ? "item_updated" : "item_finished"
            do { _ = try parseServerMessage(assistantMessage(state: state, progressType: progress)) } catch {
                Issue.record("Expected valid state \(state): \(error)")
            }
        }
        for state in [
            #""status":"streaming","stopReason":"stop""#, #""status":"complete""#,
            #""status":"complete","stopReason":"error""#,
            #""status":"error","stopReason":"error","errorMessage":"""#,
            #""status":"aborted","stopReason":"stop""#,
        ] {
            expectProtocolThrow {
                try parseServerMessage(assistantMessage(state: state, progressType: "item_finished"))
            }
        }
    }

    @Test func toolStateAndFinishedInvariants() {
        for state in [
            #""status":"running","isError":false"#, #""status":"complete","isError":false"#,
            #""status":"error","isError":true"#,
        ] {
            let progress = state.contains("running") ? "item_updated" : "item_finished"
            do { _ = try parseServerMessage(toolMessage(state: state, progressType: progress)) } catch {
                Issue.record("Expected valid state \(state): \(error)")
            }
        }
        for state in [
            #""status":"running","isError":true"#, #""status":"complete","isError":true"#,
            #""status":"error","isError":false"#,
        ] { expectProtocolThrow { try parseServerMessage(toolMessage(state: state, progressType: "item_finished")) } }
        expectProtocolThrow {
            try parseServerMessage(
                toolMessage(state: #""status":"running","isError":false"#, progressType: "item_finished"))
        }
    }

    @Test func everyCommandShapeRoundTrips() throws {
        let model = try ModelReference(provider: "test", id: "model")
        let commands: [Command] = [
            .list, .create(try .init()),
            .create(try .init(cwd: "/tmp", name: "name", model: model, thinkingLevel: .high)),
            .attach(sessionID: "s"), .detach(sessionID: "s"), .prompt(sessionID: "s", text: "hello"),
            .steer(sessionID: "s", text: "next"), .abort(sessionID: "s"),
            .setModel(sessionID: "s", model: model), .setThinking(sessionID: "s", thinkingLevel: .max),
        ]
        for (index, command) in commands.enumerated() {
            let message = ClientMessage.request(try RequestEnvelope(id: "r-\(index)", request: command))
            #expect(try parseClientMessage(message.protocolJSONValue()) == message)
            let decoder = try ClientMessageDecoder()
            #expect(try decoder.push(encodeClientMessage(message)) == [message])
        }
    }

    @Test func fragmentedAndCoalescedValidatedDecoding() throws {
        let hello = ClientMessage.hello(try ClientHello())
        let request = ClientMessage.request(try RequestEnvelope(id: "request-1", request: .list))
        var wire = try encodeClientMessage(hello)
        wire.append(try encodeClientMessage(request))
        for split in 0...wire.count {
            let decoder = try ClientMessageDecoder()
            let messages = try decoder.push(wire.prefix(split)) + decoder.push(wire.suffix(wire.count - split))
            try decoder.end()
            #expect(messages == [hello, request])
        }
    }

    @Test func validatedDecoderStickyFailuresAndFraming() throws {
        let invalid = [
            try encodeFrame(Data()), try encodeFrame(Data([0xff])),
            try encodeFrame(encodeCBOR(["type": "hello", "version": 1, "extra": true])),
        ]
        for wire in invalid {
            let decoder = try ClientMessageDecoder()
            expectProtocolThrow { try decoder.push(wire) }
            expectProtocolThrow { try decoder.push(encodeClientMessage(.hello(ClientHello()))) }
        }
        let truncated = try ServerMessageDecoder()
        #expect(try truncated.push(Data([0, 0, 0, 2, 1])) == [])
        expectProtocolThrow { try truncated.end() }
        let oversized = try ClientMessageDecoder(options: .init(maximumFrameLength: 3))
        expectProtocolThrow { try oversized.push(Data([0, 0, 0, 4])) }
    }

    @Test func rejectsCBORByteStringsInsideJSONDetails() throws {
        let value: CBORValue = [
            "type": "response", "id": "request-1", "ok": false,
            "error": [
                "code": "invalid_request", "message": "invalid",
                "details": ["nested": .byteString(Data([1, 2, 3]))],
            ],
        ]
        let wire = try encodeFrame(encodeCBOR(value))
        expectProtocolThrow { try ServerMessageDecoder().push(wire) }
    }

    @Test func outboundLimitAndTypedValidation() throws {
        expectProtocolThrow { try encodeClientMessage(.hello(ClientHello()), options: .init(maximumFrameLength: 8)) }
        expectProtocolThrow { try encodeClientMessage(.request(RequestEnvelope(id: "", request: .list))) }
        expectProtocolThrow {
            try encodeClientMessage(.request(RequestEnvelope(id: "r", request: .attach(sessionID: ""))))
        }
    }

    @Test func sequenceValidatorsEnforceHelloLifecycle() throws {
        let client = ClientProtocolSequenceValidator()
        expectProtocolThrow { try client.accept(.request(RequestEnvelope(id: "r", request: .list))) }
        let acceptedClient = ClientProtocolSequenceValidator()
        try acceptedClient.accept(.hello(ClientHello()))
        try acceptedClient.accept(.request(RequestEnvelope(id: "r", request: .list)))
        expectProtocolThrow { try acceptedClient.accept(.hello(ClientHello())) }

        let server = ServerProtocolSequenceValidator()
        expectProtocolThrow { try server.accept(.event(.sessionRemoved(sessionID: "s"))) }
        let acceptedServer = ServerProtocolSequenceValidator()
        try acceptedServer.accept(.hello(ServerHello(connectionID: "c", snapshot: emptySnapshot)))
        try acceptedServer.accept(.event(.sessionRemoved(sessionID: "s")))
        expectProtocolThrow {
            try acceptedServer.accept(.hello(ServerHello(connectionID: "c", snapshot: emptySnapshot)))
        }
    }

    private func j(_ source: String) -> JSONValue { try! OrderedJSON.decode(source) }

    private func assistantMessage(state: String, progressType: String) -> JSONValue {
        j(
            """
            {"type":"event","event":{"type":"session_progress","sessionId":"session-1",
             "progress":{"type":"\(progressType)","item":{"id":"assistant-1","role":"assistant",
             "content":[{"type":"text","text":"hello"}],"model":{"provider":"test","id":"model"},
             "timestamp":1,\(state)}}}}
            """)
    }

    private func toolMessage(state: String, progressType: String) -> JSONValue {
        j(
            """
            {"type":"event","event":{"type":"session_progress","sessionId":"session-1",
             "progress":{"type":"\(progressType)","item":{"id":"tool-1","role":"tool",
             "toolCallId":"call-1","toolName":"read","input":{},"content":[],"timestamp":1,\(state)}}}}
            """)
    }
}

private func expectProtocolThrow<Value>(_ body: () throws -> Value) {
    do {
        _ = try body()
        Issue.record("Expected operation to throw")
    } catch {}
}

private func object(_ fields: [(String, JSONValue)]) -> JSONValue {
    var object = OrderedJSONObject()
    for (key, value) in fields { object[key] = value }
    return .object(object)
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
