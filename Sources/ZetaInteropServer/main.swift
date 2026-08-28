import Darwin
import Foundation
import ZetaProtocol
import ZetaServer
import ZetaUnixTransport

@main
enum InteropServer {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: zeta-interop-server <socket>\n".utf8))
            exit(2)
        }
        do {
            let server = try PiServer(
                serverID: "zeta-interop",
                service: InMemoryService()
            )
            let listener = try UnixServerListener(
                path: CommandLine.arguments[1]
            ) { connection in
                Task {
                    try await server.accept(connection)
                    connection.start(
                        onData: { data in
                            Task {
                                await server.receive(
                                    data,
                                    connectionID: connection.id
                                )
                            }
                        },
                        onClose: {
                            Task { await server.disconnected(connection.id) }
                        }
                    )
                }
            }
            print("READY", terminator: "\n")
            fflush(stdout)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
            listener.close()
            await server.close()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}

private actor InMemoryService: PiServerService {
    private var sessions: [String: InMemoryRuntime] = [:]

    func listSessions() async throws -> [SessionMetadata] {
        try await sessions.values.asyncMap { try await $0.metadata() }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func listModels() async throws -> [ModelMetadata] {
        [
            try ModelMetadata(
                provider: "faux", id: "faux", name: "Faux", api: "faux",
                reasoning: false, input: [.text], contextWindow: 128_000,
                maxTokens: 32_000,
                cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                supportedThinkingLevels: [.off], authenticated: true
            )
        ]
    }

    func createSession(_ options: CreateCommandOptions) async throws -> any PiSessionRuntime {
        let id = UUID().uuidString.lowercased()
        let runtime = try InMemoryRuntime(
            id: id,
            cwd: options.cwd ?? FileManager.default.currentDirectoryPath,
            name: options.name,
            model: options.model ?? ModelReference(provider: "faux", id: "faux"),
            thinking: options.thinkingLevel ?? .off
        )
        sessions[id] = runtime
        return runtime
    }

    func openSession(_ id: String) async throws -> any PiSessionRuntime {
        guard let runtime = sessions[id] else { throw PiServerFailure.notFound }
        return runtime
    }
}

private actor InMemoryRuntime: PiSessionRuntime {
    nonisolated let id: String
    private let cwd: String
    private let name: String?
    private let createdAt: Int64
    private var updatedAt: Int64
    private var revision: Int64 = 0
    private var model: ModelReference
    private var thinking: ThinkingLevel
    private var transcript: [TranscriptItem] = []
    private var queued: [UserTranscriptItem] = []

    init(
        id: String,
        cwd: String,
        name: String?,
        model: ModelReference,
        thinking: ThinkingLevel
    ) throws {
        self.id = id
        self.cwd = cwd
        self.name = name
        self.model = model
        self.thinking = thinking
        createdAt = Int64(Date().timeIntervalSince1970 * 1_000)
        updatedAt = createdAt
    }

    func metadata() throws -> SessionMetadata {
        try SessionMetadata(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sessionName: name,
            cwd: cwd
        )
    }

    func snapshot(attached: Bool) throws -> SessionSnapshot {
        try SessionSnapshot(
            id: id, name: name, cwd: cwd, createdAt: createdAt,
            updatedAt: updatedAt, phase: .idle, model: model,
            thinkingLevel: thinking, attached: attached, locked: false,
            revision: revision, transcript: transcript,
            queuedSteer: queued, queuedSteerCount: Int64(queued.count)
        )
    }

    func prompt(_ text: String) throws -> SessionSnapshot {
        revision += 1
        updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        transcript.append(
            .user(
                try UserTranscriptItem(
                    id: UUID().uuidString,
                    content: [.text(TextContent(text: text))],
                    timestamp: updatedAt
                )
            )
        )
        return try snapshot(attached: true)
    }

    func steer(_ text: String) throws -> SessionSnapshot {
        updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        queued.append(
            try UserTranscriptItem(
                id: UUID().uuidString,
                content: [.text(TextContent(text: text))],
                timestamp: updatedAt
            )
        )
        revision += 1
        return try snapshot(attached: true)
    }

    func abort() throws -> SessionSnapshot {
        queued.removeAll()
        revision += 1
        return try snapshot(attached: true)
    }

    func setModel(_ model: ModelReference) throws -> SessionSnapshot {
        self.model = model
        revision += 1
        return try snapshot(attached: true)
    }

    func setThinking(_ level: ThinkingLevel) throws -> SessionSnapshot {
        thinking = level
        revision += 1
        return try snapshot(attached: true)
    }

    func dispose() {}
}

private extension Sequence {
    func asyncMap<Value>(_ transform: (Element) async throws -> Value) async rethrows -> [Value] {
        var values: [Value] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
