import Foundation
import ZetaProtocol

public protocol ServerByteConnection: Sendable {
    var id: String { get }
    func send(_ bytes: Data) async throws
    func close() async
}

public protocol PiSessionRuntime: Sendable {
    var id: String { get }
    func snapshot(attached: Bool) async throws -> SessionSnapshot
    func prompt(_ text: String) async throws -> SessionSnapshot
    func steer(_ text: String) async throws -> SessionSnapshot
    func abort() async throws -> SessionSnapshot
    func setModel(_ model: ModelReference) async throws -> SessionSnapshot
    func setThinking(_ level: ThinkingLevel) async throws -> SessionSnapshot
    func dispose() async
}

public protocol PiServerService: Sendable {
    func listSessions() async throws -> [SessionMetadata]
    func listModels() async throws -> [ModelMetadata]
    func createSession(_ options: CreateCommandOptions) async throws -> any PiSessionRuntime
    func openSession(_ id: String) async throws -> any PiSessionRuntime
}

public enum PiServerFailure: Error, Sendable {
    case busy
    case notFound
    case invalidRequest(String)
    case notImplemented
}

public actor PiServer {
    private struct ClientState {
        let connection: any ServerByteConnection
        let decoder: ClientMessageDecoder
        let sequence: ClientProtocolSequenceValidator
        var ready = false
        var attached: Set<String> = []
    }
    private struct RuntimeState {
        let runtime: any PiSessionRuntime
        var connections: Set<String> = []
        var operations = 0
    }
    private struct RuntimeOpen {
        let token: UUID
        let task: Task<any PiSessionRuntime, Error>
    }

    public let serverID: String
    private let service: any PiServerService
    private let frameOptions: FrameDecoderOptions
    private let handshakeTimeout: Duration
    private var clients: [String: ClientState] = [:]
    private var runtimes: [String: RuntimeState] = [:]
    private var runtimeOpens: [String: RuntimeOpen] = [:]
    private var revision: Int64 = 0

    public init(
        serverID: String = UUID().uuidString,
        maximumFrameLength: Int = 16 * 1_024 * 1_024,
        handshakeTimeout: Duration = .seconds(5),
        service: any PiServerService
    ) throws {
        self.serverID = serverID
        self.service = service
        self.handshakeTimeout = handshakeTimeout
        frameOptions = FrameDecoderOptions(maximumFrameLength: maximumFrameLength)
    }

    public func accept(_ connection: any ServerByteConnection) throws {
        clients[connection.id] = ClientState(
            connection: connection,
            decoder: try ClientMessageDecoder(options: frameOptions),
            sequence: ClientProtocolSequenceValidator()
        )
        let connectionID = connection.id
        Task {
            try? await Task.sleep(for: handshakeTimeout)
            await handshakeTimedOut(connectionID)
        }
    }

    public func receive(_ data: Data, connectionID: String) {
        guard let client = clients[connectionID] else { return }
        do {
            for message in try client.decoder.push(data) {
                try client.sequence.accept(message)
                switch message {
                case .hello(let hello): Task { await self.handshake(hello, connectionID: connectionID) }
                case .request(let request):
                    guard client.ready else { throw PiServerFailure.invalidRequest("Request before handshake") }
                    Task { await self.dispatch(request, connectionID: connectionID) }
                }
            }
        } catch { Task { await self.close(connectionID, finalError: self.protocolError(error)) } }
    }

    public func disconnected(_ connectionID: String) async {
        guard let client = clients.removeValue(forKey: connectionID) else { return }
        for id in client.attached { await detachRuntime(id, connectionID: connectionID) }
    }

    public func close() async {
        let values = clients.values.map(\.connection)
        clients.removeAll()
        for value in values { await value.close() }
        let runtimeValues = runtimes.values.map(\.runtime)
        runtimes.removeAll()
        let openingTasks = runtimeOpens.values.map(\.task)
        runtimeOpens.removeAll()
        for task in openingTasks { task.cancel() }
        for runtime in runtimeValues { await runtime.dispose() }
    }

    private func handshakeTimedOut(_ connectionID: String) async {
        guard let client = clients[connectionID], !client.ready else { return }
        await close(
            connectionID,
            finalError: try? ProtocolErrorValue(
                code: .invalidRequest,
                message: "Protocol handshake timed out"
            )
        )
    }

    private func handshake(_ hello: ClientHello, connectionID: String) async {
        guard var client = clients[connectionID] else { return }
        guard isSupportedProtocolVersion(hello.version) else {
            await close(
                connectionID,
                finalError: try? ProtocolErrorValue(code: .version, message: "Unsupported protocol version"))
            return
        }
        do {
            let snapshot = try await serverSnapshot()
            try await client.connection.send(
                encodeServerMessage(
                    .hello(try ServerHello(connectionID: connectionID, snapshot: snapshot)), options: frameOptions))
            client.ready = true
            clients[connectionID] = client
        } catch { await close(connectionID, finalError: protocolError(error)) }
    }

    private func dispatch(_ request: RequestEnvelope, connectionID: String) async {
        do {
            let result = try await execute(request.request, connectionID: connectionID)
            try await send(.response(.success(id: request.id, result: result)), to: connectionID)
        } catch {
            let value = protocolError(error)
            try? await send(.response(.failure(id: request.id, error: value)), to: connectionID)
        }
    }

    private func execute(_ command: Command, connectionID: String) async throws -> CommandResult {
        switch command {
        case .list: return .list(try await service.listSessions())
        case .create(let options):
            let runtime = try await service.createSession(options)
            guard runtimes[runtime.id] == nil else {
                await runtime.dispose()
                throw PiServerFailure.busy
            }
            runtimes[runtime.id] = RuntimeState(runtime: runtime, connections: [connectionID])
            clients[connectionID]?.attached.insert(runtime.id)
            await broadcastServerSnapshot()
            return .create(try await runtime.snapshot(attached: true))
        case .attach(let id):
            let runtime = try await openRuntime(id)
            runtimes[id]?.connections.insert(connectionID)
            clients[connectionID]?.attached.insert(id)
            return .attach(try await runtime.snapshot(attached: true))
        case .detach(let id):
            await detachRuntime(id, connectionID: connectionID)
            return .detach(sessionID: id)
        case .prompt(let id, let text):
            return .prompt(
                try await mutateAttachedRuntime(id, connectionID: connectionID) { try await $0.prompt(text) })
        case .steer(let id, let text):
            return .steer(
                try await mutateAttachedRuntime(id, connectionID: connectionID) { try await $0.steer(text) })
        case .abort(let id):
            return .abort(try await mutateAttachedRuntime(id, connectionID: connectionID) { try await $0.abort() })
        case .setModel(let id, let model):
            return .setModel(
                try await mutateAttachedRuntime(id, connectionID: connectionID) { try await $0.setModel(model) })
        case .setThinking(let id, let level):
            return .setThinking(
                try await mutateAttachedRuntime(id, connectionID: connectionID) { try await $0.setThinking(level) })
        }
    }

    private func withAttachedRuntime<T: Sendable>(
        _ id: String, connectionID: String, body: @Sendable (any PiSessionRuntime) async throws -> T
    ) async throws -> T {
        guard clients[connectionID]?.attached.contains(id) == true, var state = runtimes[id] else {
            throw PiServerFailure.notFound
        }
        state.operations += 1
        runtimes[id] = state
        do {
            let value = try await body(state.runtime)
            await operationFinished(id)
            return value
        } catch {
            await operationFinished(id)
            throw error
        }
    }

    private func mutateAttachedRuntime(
        _ id: String,
        connectionID: String,
        body: @Sendable (any PiSessionRuntime) async throws -> SessionSnapshot
    ) async throws -> SessionSnapshot {
        let snapshot = try await withAttachedRuntime(id, connectionID: connectionID, body: body)
        guard snapshot.id == id else { throw PiServerFailure.invalidRequest("Runtime session id mismatch") }
        let eventSnapshot = try snapshot.withAttachment(true)
        await broadcastSessionSnapshot(eventSnapshot, sessionID: id)
        let requesterIsAttached = clients[connectionID]?.attached.contains(id) == true
        return requesterIsAttached ? eventSnapshot : try snapshot.withAttachment(false)
    }

    private func operationFinished(_ id: String) async {
        guard var state = runtimes[id] else { return }
        state.operations -= 1
        runtimes[id] = state
        if state.operations == 0 && state.connections.isEmpty {
            runtimes[id] = nil
            await state.runtime.dispose()
        }
    }

    private func openRuntime(_ id: String) async throws -> any PiSessionRuntime {
        if let state = runtimes[id] { return state.runtime }

        let opening: RuntimeOpen
        if let existing = runtimeOpens[id] {
            opening = existing
        } else {
            let token = UUID()
            let service = service
            let task = Task.detached { () throws -> any PiSessionRuntime in
                let runtime = try await service.openSession(id)
                guard !Task.isCancelled else {
                    await runtime.dispose()
                    throw CancellationError()
                }
                guard runtime.id == id else {
                    await runtime.dispose()
                    throw PiServerFailure.invalidRequest("Runtime session id mismatch")
                }
                return runtime
            }
            opening = RuntimeOpen(token: token, task: task)
            runtimeOpens[id] = opening
        }

        do {
            let runtime = try await opening.task.value
            if runtimeOpens[id]?.token == opening.token {
                runtimeOpens[id] = nil
                if let state = runtimes[id] {
                    Task.detached { await runtime.dispose() }
                    return state.runtime
                }
                runtimes[id] = RuntimeState(runtime: runtime)
                return runtime
            }
            if let state = runtimes[id] { return state.runtime }
            await runtime.dispose()
            throw PiServerFailure.busy
        } catch {
            if runtimeOpens[id]?.token == opening.token { runtimeOpens[id] = nil }
            throw error
        }
    }

    private func detachRuntime(_ id: String, connectionID: String) async {
        clients[connectionID]?.attached.remove(id)
        guard var state = runtimes[id] else { return }
        state.connections.remove(connectionID)
        runtimes[id] = state
        if state.connections.isEmpty && state.operations == 0 {
            runtimes[id] = nil
            await state.runtime.dispose()
        }
    }

    private func serverSnapshot() async throws -> ServerSnapshot {
        try ServerSnapshot(
            serverID: serverID, revision: revision, sessions: try await service.listSessions(),
            models: try await service.listModels())
    }

    private func broadcastSessionSnapshot(_ snapshot: SessionSnapshot, sessionID: String) async {
        let connections = runtimes[sessionID]?.connections.compactMap { clients[$0]?.connection } ?? []
        guard !connections.isEmpty,
            let encoded = try? encodeServerMessage(.event(.sessionSnapshot(snapshot)), options: frameOptions)
        else { return }
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask { try? await connection.send(encoded) }
            }
        }
    }

    private func broadcastServerSnapshot() async {
        let ready = clients.values.filter(\.ready)
        guard !ready.isEmpty else { return }
        revision += 1
        guard let snapshot = try? await serverSnapshot(),
            let encoded = try? encodeServerMessage(.event(.serverSnapshot(snapshot)), options: frameOptions)
        else { return }
        for client in ready { try? await client.connection.send(encoded) }
    }

    private func send(_ message: ServerMessage, to id: String) async throws {
        guard let connection = clients[id]?.connection else { return }
        try await connection.send(encodeServerMessage(message, options: frameOptions))
    }

    private func close(_ id: String, finalError: ProtocolErrorValue?) async {
        guard let client = clients[id] else { return }
        if let finalError, let encoded = try? encodeServerMessage(.helloError(finalError), options: frameOptions) {
            try? await client.connection.send(encoded)
        }
        await client.connection.close()
        await disconnected(id)
    }

    private func protocolError(_ error: Error) -> ProtocolErrorValue {
        if let error = error as? PiServerFailure {
            switch error {
            case .busy: return try! ProtocolErrorValue(code: .busy, message: "Session is busy")
            case .notFound: return try! ProtocolErrorValue(code: .notFound, message: "Session not found")
            case .invalidRequest(let message): return try! ProtocolErrorValue(code: .invalidRequest, message: message)
            case .notImplemented:
                return try! ProtocolErrorValue(code: .notImplemented, message: "Operation is not implemented")
            }
        }
        return try! ProtocolErrorValue(code: .internalError, message: "Internal server error")
    }
}

private extension SessionSnapshot {
    func withAttachment(_ attached: Bool) throws -> SessionSnapshot {
        try SessionSnapshot(
            id: id, name: name, cwd: cwd, createdAt: createdAt, updatedAt: updatedAt, phase: phase,
            model: model, thinkingLevel: thinkingLevel, attached: attached, locked: locked, revision: revision,
            transcript: transcript, queuedSteer: queuedSteer, queuedSteerCount: queuedSteerCount)
    }
}
