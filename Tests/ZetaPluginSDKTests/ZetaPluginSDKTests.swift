import Foundation
import XCTest
import ZetaPluginAPI

@testable import ZetaPluginSDK

final class ZetaPluginSDKTests: XCTestCase {
    func testInitializeAndCallbackProtocol() async throws {
        let input = Pipe()
        let output = Pipe()
        let definition = PluginDefinition(
            registrations: [
                PluginRegistration(kind: .tool, name: "echo", callback: "tool.echo"),
                PluginRegistration(kind: .command, name: "hello", callback: "command.hello"),
                PluginRegistration(kind: .provider, name: "provider", callback: "provider.stream"),
                PluginRegistration(kind: .event, name: "input", callback: "event.input"),
                PluginRegistration(kind: .resource, name: "skills", callback: "resource.skills"),
                PluginRegistration(kind: .ui, name: "dialog", callback: "ui.dialog"),
            ],
            callbacks: [
                PluginCallback(id: "tool.echo") { $0 },
                PluginCallback(id: "command.hello") { _ in Data("hello".utf8) },
            ]
        )
        let task = Task {
            try await PluginSDK.run(
                definition: definition,
                input: input.fileHandleForReading,
                output: output.fileHandleForWriting,
                environment: [
                    "ZETA_PLUGIN_PROTOCOL": "1",
                    "ZETA_PLUGIN_GENERATION": "7",
                ]
            )
        }
        let initialize = PluginEnvelope(
            id: "1",
            type: "request",
            generation: 7,
            method: "initialize"
        )
        var request = try JSONEncoder().encode(initialize)
        request.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: request)
        let line = try readLine(output.fileHandleForReading)
        let response = try JSONDecoder().decode(PluginEnvelope.self, from: line)
        XCTAssertEqual(response.id, "1")
        XCTAssertEqual(
            try JSONDecoder().decode([PluginRegistration].self, from: response.payload!).count,
            6
        )
        try input.fileHandleForWriting.close()
        try await task.value
    }
}

private func readLine(_ handle: FileHandle) throws -> Data {
    var data = Data()
    while true {
        guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { return data }
        if byte[0] == 0x0A { return data }
        data.append(byte)
    }
}
