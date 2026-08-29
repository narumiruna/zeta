import Foundation
import XCTest
import ZetaAI
import ZetaAgent
import ZetaCompaction
import ZetaModes
import ZetaSessionFormat
import ZetaSessions

@testable import ZetaCLI

final class RPCSessionFeedbackTests: XCTestCase {
    func testRPCPromptSteerAndFollowUpPreserveTextAndDecodeImages() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        for index in 1...3 {
            await provider.enqueue(
                AssistantMessage(
                    content: [.text(text: "response \(index)")],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: .stop
                )
            )
        }
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]).base64EncodedString()

        for (command, text) in [(RPCCommandName.steer, "steered"), (.followUp, "followed")] {
            let response = await runtime.handle(
                try imageRequest(command: command, text: text, data: imageData)
            )
            XCTAssertTrue(response.success)
        }
        let prompt = await runtime.handle(
            try imageRequest(command: .prompt, text: "prompted", data: imageData)
        )
        XCTAssertTrue(prompt.success)
        await runtime.waitForIdle()

        let users = await agent.state().messages.compactMap { message -> UserMessage? in
            guard case .user(let user) = message else { return nil }
            return user
        }
        XCTAssertEqual(users.count, 3)
        XCTAssertEqual(users.map(text), ["prompted", "steered", "followed"])
        for user in users {
            XCTAssertEqual(user.content.count, 2)
            XCTAssertEqual(user.content[1], .image(data: imageData, mimeType: "image/png"))
        }
    }

    func testRPCImageSchemaAndRuntimeValidationAreStrict() async throws {
        for record in [
            #"{"type":"prompt","message":"x","images":["not-an-object"]}"#,
            #"{"type":"steer","message":"x","images":[{"type":"image","data":"eA=="}]}"#,
            #"{"type":"follow_up","message":"x","images":[{"type":"image","data":"eA==","mimeType":"image/png","extra":true}]}"#,
        ] {
            XCTAssertThrowsError(try StrictRPCRequest.decode(Data(record.utf8)))
        }

        let provider = FauxProvider()
        let model = await provider.models[0]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let invalidRequests = [
            try imageRequest(command: .prompt, text: "x", data: "not-base64"),
            try imageRequest(command: .prompt, text: "x", data: "iVBORx=="),
            try imageRequest(command: .steer, text: "x", data: Data("plain".utf8).base64EncodedString()),
            try imageRequest(command: .followUp, text: "x", data: png, mimeType: "text/plain"),
            try imageRequest(command: .prompt, text: "x", data: png, mimeType: "image/jpeg"),
        ]
        for request in invalidRequests {
            let response = await runtime.handle(request)
            XCTAssertFalse(response.success)
            XCTAssertNotNil(response.error)
        }
        let callCount = await provider.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testRepeatedCompactionPersistsProjectedRetainedEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        let header = SessionHeader(
            id: "repeated-compaction",
            timestamp: "2026-01-01T00:00:00Z",
            cwd: root.path
        )
        let manager = try SessionManager(header: header, file: file)
        var parentID: String?
        for (index, value) in ["old-one", "old-two", "kept-one", "kept-two"].enumerated() {
            let id = String(format: "%08d", index + 1)
            try await manager.append(
                .message(
                    SessionEntryBase(id: id, parentId: parentID, timestamp: header.timestamp),
                    .user(UserMessage(value, timestamp: Int64(index + 1)))
                )
            )
            parentID = id
        }
        try await manager.materialize()
        let session = PersistentSessionController(manager: manager)

        let firstMessages = try await manager.context().messages
        let firstPreparation = try preparation(messages: firstMessages, expectedRetainedIndex: 2)
        try await session.recordCompaction(
            summary: "summary-one",
            preparation: firstPreparation
        )
        parentID = await manager.leaf()?.base.id
        for (offset, value) in ["new-one", "new-two"].enumerated() {
            let id = String(format: "%08d", offset + 5)
            try await manager.append(
                .message(
                    SessionEntryBase(id: id, parentId: parentID, timestamp: header.timestamp),
                    .user(UserMessage(value, timestamp: Int64(offset + 5)))
                )
            )
            parentID = id
        }

        let secondMessages = try await manager.context().messages
        XCTAssertEqual(
            secondMessages.map(messageText),
            [
                "Summary of previous conversation (\(firstPreparation.estimatedTokensBefore) tokens):\nsummary-one",
                "kept-one",
                "kept-two",
                "new-one",
                "new-two",
            ])
        let secondPreparation = try preparation(messages: secondMessages, expectedRetainedIndex: 3)
        try await session.recordCompaction(
            summary: "summary-two",
            preparation: secondPreparation
        )

        let reloaded = try SessionManager.load(file: file)
        let restored = try await reloaded.context().messages.map(messageText)
        XCTAssertEqual(
            restored,
            [
                "Summary of previous conversation (\(secondPreparation.estimatedTokensBefore) tokens):\nsummary-two",
                "new-one",
                "new-two",
            ])
        XCTAssertFalse(restored.joined().contains("kept-two"))
        XCTAssertFalse(restored.joined().contains("old-one"))
    }

    func testRPCCompactionPassesCustomInstructionsToSummaryPrompt() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "summary")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        let recorder = ContextRecorder()
        let seeded: [Message] = [
            .user(UserMessage("first")),
            .assistant(
                AssistantMessage(
                    content: [.text(text: "second")],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: .stop
                )
            ),
            .user(UserMessage("third")),
        ]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model, messages: seeded)) {
            model, context, options in
            await recorder.record(context)
            return await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        let response = await runtime.handle(
            StrictRPCRequest(
                command: .compact,
                fields: ["customInstructions": "Focus on unresolved tests."]
            )
        )
        XCTAssertTrue(response.success)
        let contexts = await recorder.values()
        XCTAssertEqual(contexts.count, 1)
        XCTAssertTrue(messageText(contexts[0].messages[0]).hasPrefix("Focus on unresolved tests.\n\n"))
    }

    func testRPCExportEmbedsPersistentCodingAgentV3JSONL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.jsonl")
        let header = SessionHeader(
            id: "persistent-export",
            timestamp: "2026-01-01T00:00:00Z",
            cwd: root.path
        )
        let message = Message.user(UserMessage("persisted", timestamp: 1))
        let entry = SessionEntry.message(
            SessionEntryBase(id: "00000001", parentId: nil, timestamp: header.timestamp),
            message
        )
        let manager = try SessionManager(header: header, entries: [entry], file: source)
        try await manager.materialize()
        let session = PersistentSessionController(manager: manager)
        let runtime = try await runtime(messages: [message], workingDirectory: root, session: session)

        let downloaded = try await exportedJSONL(from: runtime, in: root, name: "persistent-download.jsonl")
        XCTAssertEqual(try SessionFormatDetector.detect(file: downloaded), .codingAgent(version: 3))
        let loaded = try SessionManager.load(file: downloaded)
        let loadedHeader = await loaded.header
        let entries = await loaded.allEntries()
        XCTAssertEqual(loadedHeader, header)
        XCTAssertEqual(entries, [entry])
    }

    func testRPCExportSynthesizesLoadableCodingAgentV3JSONLWithoutSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let provider = FauxProvider()
        let model = await provider.models[0]
        let messages: [Message] = [
            .user(UserMessage("hello", timestamp: 1)),
            .assistant(
                AssistantMessage(
                    content: [.text(text: "world")],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: .stop,
                    timestamp: 2
                )
            ),
        ]
        let runtime = try await runtime(messages: messages, workingDirectory: root)

        let downloaded = try await exportedJSONL(from: runtime, in: root, name: "memory-download.jsonl")
        XCTAssertEqual(try SessionFormatDetector.detect(file: downloaded), .codingAgent(version: 3))
        let loaded = try SessionManager.load(file: downloaded)
        let loadedHeader = await loaded.header
        XCTAssertEqual(loadedHeader.version, currentCodingSessionVersion)
        XCTAssertEqual(loadedHeader.cwd, root.path)
        let restoredMessages = try await loaded.context().messages
        let entryCount = await loaded.allEntries().count
        XCTAssertEqual(restoredMessages, messages)
        XCTAssertEqual(entryCount, messages.count)
    }

    private func imageRequest(
        command: RPCCommandName,
        text: String,
        data: String,
        mimeType: String = "image/png"
    ) throws -> StrictRPCRequest {
        try StrictRPCRequest.decode(
            Data(
                """
                {"type":"\(command.rawValue)","message":"\(text)","images":[{"type":"image","data":"\(data)","mimeType":"\(mimeType)"}]}
                """.utf8
            )
        )
    }

    private func preparation(
        messages: [Message],
        expectedRetainedIndex: Int
    ) throws -> CompactionPreparation {
        let result = try XCTUnwrap(
            Compaction.prepare(
                messages: messages,
                settings: CompactionSettings(keepRecentTokens: 3)
            )
        )
        XCTAssertEqual(result.firstRetainedMessageIndex, expectedRetainedIndex)
        return result
    }

    private func runtime(
        messages: [Message],
        workingDirectory: URL,
        session: PersistentSessionController? = nil
    ) async throws -> CLIRPCRuntime {
        let provider = FauxProvider()
        let model = await provider.models[0]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model, messages: messages)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        return CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: workingDirectory,
            session: session
        )
    }

    private func exportedJSONL(
        from runtime: CLIRPCRuntime,
        in directory: URL,
        name: String
    ) async throws -> URL {
        let response = await runtime.handle(StrictRPCRequest(command: .exportHTML))
        XCTAssertTrue(response.success)
        guard case .object(let data)? = response.data,
            case .string(let html)? = data["html"]
        else {
            throw TestError.missingExport
        }
        let marker = "const sessionBase64=\""
        guard let markerRange = html.range(of: marker),
            let end = html[markerRange.upperBound...].firstIndex(of: "\"")
        else {
            throw TestError.missingExport
        }
        let encoded = String(html[markerRange.upperBound..<end])
        guard let jsonl = Data(base64Encoded: encoded) else {
            throw TestError.missingExport
        }
        let file = directory.appendingPathComponent(name)
        try jsonl.write(to: file)
        return file
    }

    private func text(_ message: UserMessage) -> String {
        message.content.compactMap { block in
            if case .text(let text, _) = block { text } else { nil }
        }.joined()
    }

    private func messageText(_ message: Message) -> String {
        switch message {
        case .user(let user): text(user)
        case .assistant(let assistant):
            assistant.content.compactMap { block in
                if case .text(let text, _) = block { text } else { nil }
            }.joined()
        case .toolResult(let result):
            result.content.compactMap { block in
                if case .text(let text, _) = block { text } else { nil }
            }.joined()
        case .custom(let custom):
            String(describing: custom.content)
        }
    }
}

private actor ContextRecorder {
    private var contexts: [Context] = []

    func record(_ context: Context) {
        contexts.append(context)
    }

    func values() -> [Context] {
        contexts
    }
}

private enum TestError: Error {
    case missingExport
}
