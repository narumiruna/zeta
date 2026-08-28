import XCTest
import ZetaAI
import ZetaAgent
import ZetaCore
import ZetaModes

@testable import ZetaCLI

final class ZetaCLITests: XCTestCase {
    func testImageMagicDetection() {
        XCTAssertEqual(
            ZetaCLI.imageMIME(Data([0x89, 0x50, 0x4E, 0x47, 0x00])),
            "image/png"
        )
        XCTAssertEqual(
            ZetaCLI.imageMIME(Data("RIFFxxxxWEBP".utf8)),
            "image/webp"
        )
        XCTAssertNil(ZetaCLI.imageMIME(Data("plain".utf8)))
    }

    func testArgumentConflictsAndExtensionFlags() throws {
        let args = try CLIArguments.parse(["--custom=value", "-p", "hello"])
        XCTAssertEqual(args.extensionFlags["custom"]!, "value")
        XCTAssertTrue(args.print)
        XCTAssertEqual(args.messages, ["hello"])
        XCTAssertThrowsError(try CLIArguments.parse(["--fork", "a", "--session", "b"]))
        XCTAssertThrowsError(try CLIArguments.parse(["--session-id", "-invalid-"]))
        let model = try CLIArguments.parse(["--model", "openai/gpt:high", "hello"])
        XCTAssertEqual(model.model, "openai/gpt")
        XCTAssertEqual(model.thinking, .high)
        XCTAssertTrue(model.thinkingSpecified)
    }

    func testJSONUpdateIsDeltaOnly() throws {
        let partial = AssistantMessage(
            content: [.text(text: "hello")],
            api: "faux",
            provider: "faux",
            model: "faux"
        )
        let event = AgentEvent.messageUpdate(
            partial,
            .textDelta(index: 0, delta: "o", partial: partial)
        )
        let value = try OrderedJSON.decode(
            JSONEncoder().encode(JSONAgentEvent(event))
        )
        guard case .object(let object) = value,
            case .object(let update)? = object["assistantMessageEvent"]
        else {
            return XCTFail("Expected JSON update")
        }
        XCTAssertNil(object["message"])
        XCTAssertNil(update["partial"])
        XCTAssertEqual(update["delta"], "o")
        XCTAssertEqual(update["contentIndex"], 0)
    }

    func testRPCRuntimeAcceptsPromptAndStateCommands() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "ok")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        let agent = Agent(
            state: AgentState(systemPrompt: "", model: model)
        ) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let prompt = try StrictRPCRequest.decode(
            Data(
                #"{"id":"1","type":"prompt","message":"hello"}"#.utf8
            )
        )
        let accepted = await runtime.handle(prompt)
        XCTAssertTrue(accepted.success)
        await runtime.afterResponse(prompt)
        await agent.waitForIdle()
        let state = await runtime.handle(
            StrictRPCRequest(
                id: "2",
                command: .getState,
                fields: [:]
            )
        )
        XCTAssertTrue(state.success)
        guard case .object(let stateData)? = state.data else {
            return XCTFail("Expected state")
        }
        XCTAssertEqual(stateData["messageCount"], 2)
    }

    func testModeResolution() throws {
        XCTAssertEqual(try CLIArguments.parse([]).effectiveMode(stdinIsTTY: true, stdoutIsTTY: true), .interactive)
        XCTAssertEqual(try CLIArguments.parse([]).effectiveMode(stdinIsTTY: false, stdoutIsTTY: true), .print)
        XCTAssertEqual(
            try CLIArguments.parse(["--mode", "rpc"]).effectiveMode(stdinIsTTY: false, stdoutIsTTY: false), .rpc)
    }
}
