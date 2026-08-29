import Foundation
import ZetaPluginAPI

public struct PluginCallback: Sendable {
    public var id: String
    public var handle: @Sendable (Data?) async throws -> Data?

    public init(
        id: String,
        handle: @escaping @Sendable (Data?) async throws -> Data?
    ) {
        self.id = id
        self.handle = handle
    }
}

public struct PluginDefinition: Sendable {
    public var registrations: [PluginRegistration]
    public var callbacks: [String: PluginCallback]

    public init(
        registrations: [PluginRegistration],
        callbacks: [PluginCallback]
    ) {
        self.registrations = registrations
        self.callbacks = Dictionary(
            uniqueKeysWithValues: callbacks.map { ($0.id, $0) }
        )
    }
}

public enum PluginSDKError: Error, LocalizedError, Sendable {
    case invalidEnvironment
    case unknownCallback(String)
    case malformedEnvelope

    public var errorDescription: String? {
        switch self {
        case .invalidEnvironment: "Plugin host environment is invalid"
        case .unknownCallback(let value): "Unknown plugin callback: \(value)"
        case .malformedEnvelope: "Plugin request envelope is malformed"
        }
    }
}

public enum PluginSDK {
    public static func run(
        definition: PluginDefinition,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard let rawGeneration = environment["ZETA_PLUGIN_GENERATION"],
            let generation = UInt64(rawGeneration),
            environment["ZETA_PLUGIN_PROTOCOL"]
                == String(zetaPluginProtocolVersion)
        else {
            throw PluginSDKError.invalidEnvironment
        }
        var decoder = PluginLineDecoder()
        for try await byte in input.bytes {
            for line in decoder.push(byte) {
                try await respond(
                    line: line,
                    generation: generation,
                    definition: definition,
                    output: output
                )
            }
        }
        if let line = decoder.finish() {
            try await respond(
                line: line,
                generation: generation,
                definition: definition,
                output: output
            )
        }
    }

    private static func respond(
        line: Data,
        generation: UInt64,
        definition: PluginDefinition,
        output: FileHandle
    ) async throws {
        let request = try JSONDecoder().decode(PluginEnvelope.self, from: line)
        guard request.type == "request", request.generation == generation,
            let id = request.id, let method = request.method
        else {
            throw PluginSDKError.malformedEnvelope
        }
        let response: PluginEnvelope
        do {
            let payload: Data?
            if method == "initialize" {
                payload = try JSONEncoder().encode(definition.registrations)
            } else {
                guard let callback = definition.callbacks[method] else {
                    throw PluginSDKError.unknownCallback(method)
                }
                payload = try await callback.handle(request.payload)
            }
            response = PluginEnvelope(
                id: id,
                type: "response",
                generation: generation,
                payload: payload
            )
        } catch {
            response = PluginEnvelope(
                id: id,
                type: "response",
                generation: generation,
                error: String(describing: error)
            )
        }
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        try output.write(contentsOf: data)
    }
}

private struct PluginLineDecoder {
    private var buffer = Data()
    mutating func push(_ byte: UInt8) -> [Data] {
        if byte == 0x0A {
            defer { buffer.removeAll() }
            if buffer.last == 0x0D { buffer.removeLast() }
            return [buffer]
        }
        buffer.append(byte)
        return []
    }
    mutating func finish() -> Data? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return buffer
    }
}
