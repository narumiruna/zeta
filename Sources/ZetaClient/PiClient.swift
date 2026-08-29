import Foundation
import ZetaProtocol

public protocol ByteTransport: Sendable {
    func send(_ bytes: Data) async throws
    func close() async
}

public struct ByteTransportHandlers: Sendable {
    public var onData: @Sendable (Data) -> Void
    public var onClose: @Sendable () -> Void
    public var onError: @Sendable (Error) -> Void
    public init(
        onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.onData = onData
        self.onClose = onClose
        self.onError = onError
    }
}

public typealias ByteTransportFactory = @Sendable (ByteTransportHandlers) async throws -> any ByteTransport

public enum ClientConnectionState: String, Sendable { case disconnected, connecting, connected }
public enum LeaseMode: String, Sendable { case shared, exclusive }

public enum PiClientError: Error, LocalizedError, Sendable {
    case disconnected
    case disposed
    case protocolFailure(String)
    case server(ProtocolErrorValue)
    case ownership
    case detached
    public var errorDescription: String? {
        switch self {
        case .disconnected: "Pi client is disconnected"
        case .disposed: "Pi client has been disposed"
        case .protocolFailure(let value): "Pi protocol failure: \(value)"
        case .server(let value): "Pi server error [\(value.code.rawValue)]: \(value.message)"
        case .ownership: "Session lease ownership conflicts with an existing lease"
        case .detached: "Session lease is detached"
        }
    }
}

public actor PiClient {
    private static let maximumCancelledRequestIDs = 1_024

    private struct ConnectionOperation {
        let token: UUID
        let task: Task<Void, Error>
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }
    private struct HandshakeOperation {
        let generation: UInt64
        let continuation: CheckedContinuation<ServerSnapshot, Error>
        let timeoutTask: Task<Void, Never>
    }
    private struct AttachmentOperation {
        let token: UUID
        let task: Task<SessionSnapshot, Error>
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    }
    private struct DetachmentOperation {
        let token: UUID
        let task: Task<Void, Error>
    }
    private struct LeaseBook {
        var exclusive: UUID?
        var shared: Set<UUID> = []
        var attached = false
        var attachment: AttachmentOperation?
        var detachment: DetachmentOperation?
    }
    private var generation: UInt64 = 0
    private var disposed = false
    private var connectionOperation: ConnectionOperation?
    private var transport: (any ByteTransport)?
    private var decoder: ServerMessageDecoder?
    private var pending: [String: CheckedContinuation<ResponseEnvelope, Error>] = [:]
    private var cancelledRequestIDs: Set<String> = []
    private var handshake: HandshakeOperation?
    private var leases: [String: LeaseBook] = [:]
    private var sessionSnapshots: [String: SessionSnapshot] = [:]
    private var snapshotValue: ServerSnapshot?
    private var stateValue: ClientConnectionState = .disconnected
    private var snapshotListeners: [UUID: @Sendable (ServerSnapshot) -> Void] = [:]
    private var eventListeners: [UUID: @Sendable (ServerEvent) -> Void] = [:]
    private let factory: ByteTransportFactory
    private let options: FrameDecoderOptions
    private let handshakeTimeout: Duration

    public init(
        maximumFrameLength: Int = 16 * 1_024 * 1_024,
        transportFactory: @escaping ByteTransportFactory
    ) throws {
        try self.init(
            maximumFrameLength: maximumFrameLength,
            handshakeTimeout: .seconds(5),
            transportFactory: transportFactory
        )
    }

    public init(
        maximumFrameLength: Int = 16 * 1_024 * 1_024,
        handshakeTimeout: Duration,
        transportFactory: @escaping ByteTransportFactory
    ) throws {
        options = FrameDecoderOptions(maximumFrameLength: maximumFrameLength)
        self.handshakeTimeout = handshakeTimeout
        factory = transportFactory
    }

    public func connectionState() -> ClientConnectionState { stateValue }
    public func snapshot() -> ServerSnapshot? { snapshotValue }
    public func sessionSnapshot(_ id: String) -> SessionSnapshot? { sessionSnapshots[id] }

    public func connect() async throws {
        try Task.checkCancellation()
        guard !disposed else { throw PiClientError.disposed }
        let operation: ConnectionOperation
        if stateValue == .connected {
            return
        } else if stateValue == .connecting, let current = connectionOperation {
            operation = current
        } else {
            let nextDecoder = try ServerMessageDecoder(options: options)
            generation &+= 1
            let activeGeneration = generation
            decoder = nextDecoder
            stateValue = .connecting
            let token = UUID()
            let task = Task { try await self.performConnection(generation: activeGeneration) }
            operation = ConnectionOperation(token: token, task: task)
            connectionOperation = operation
            Task { await self.observeConnection(operation) }
        }
        try await waitForConnection(operation.token)
    }

    private func waitForConnection(_ operationToken: UUID) async throws {
        let waiterToken = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                guard var operation = connectionOperation, operation.token == operationToken else {
                    if stateValue == .connected {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: PiClientError.disconnected)
                    }
                    return
                }
                operation.waiters[waiterToken] = continuation
                connectionOperation = operation
            }
        } onCancel: {
            Task { await self.cancelConnectionWaiter(operationToken, waiterToken: waiterToken) }
        }
    }

    private func observeConnection(_ operation: ConnectionOperation) async {
        do {
            try await operation.task.value
            completeConnection(operation.token, result: .success(()))
        } catch {
            completeConnection(operation.token, result: .failure(error))
        }
    }

    private func completeConnection(_ token: UUID, result: Result<Void, Error>) {
        guard let operation = connectionOperation, operation.token == token else { return }
        connectionOperation = nil
        for waiter in operation.waiters.values { waiter.resume(with: result) }
    }

    private func cancelConnectionWaiter(_ token: UUID, waiterToken: UUID) async {
        guard var operation = connectionOperation, operation.token == token,
            let waiter = operation.waiters.removeValue(forKey: waiterToken)
        else { return }
        waiter.resume(throwing: CancellationError())
        if operation.waiters.isEmpty {
            connectionOperation = nil
            guard stateValue == .connecting else { return }
            operation.task.cancel()
            await fail(CancellationError(), close: true)
        } else {
            connectionOperation = operation
        }
    }

    private func performConnection(generation activeGeneration: UInt64) async throws {
        do {
            let transport = try await factory(
                ByteTransportHandlers(
                    onData: { [weak self] data in Task { await self?.receive(data, generation: activeGeneration) } },
                    onClose: { [weak self] in Task { await self?.closed(generation: activeGeneration, error: nil) } },
                    onError: { [weak self] error in
                        Task { await self?.closed(generation: activeGeneration, error: error) }
                    }
                ))
            guard generation == activeGeneration, stateValue == .connecting else {
                await transport.close()
                throw PiClientError.disconnected
            }
            self.transport = transport
            let hello = try encodeClientMessage(.hello(try ClientHello()), options: options)
            let timeout = handshakeTimeout
            let snapshot = try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task.detached { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.handshakeTimedOut(generation: activeGeneration)
                }
                handshake = HandshakeOperation(
                    generation: activeGeneration,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { await self.sendHello(hello, using: transport, generation: activeGeneration) }
            }
            guard generation == activeGeneration, stateValue == .connecting else {
                throw PiClientError.disconnected
            }
            snapshotValue = snapshot
            stateValue = .connected
        } catch {
            if generation == activeGeneration { await fail(error, close: true) }
            throw error
        }
    }

    private func sendHello(_ hello: Data, using transport: any ByteTransport, generation activeGeneration: UInt64) async
    {
        do {
            try await transport.send(hello)
        } catch {
            guard generation == activeGeneration else { return }
            await fail(error, close: true)
        }
    }

    private func handshakeTimedOut(generation timedOutGeneration: UInt64) async {
        guard handshake?.generation == timedOutGeneration else { return }
        await fail(
            PiClientError.protocolFailure("Server handshake timed out"),
            close: true
        )
    }

    public func reconnect() async throws {
        await disconnect()
        try await connect()
    }

    public func disconnect() async {
        guard !disposed else { return }
        await fail(PiClientError.disconnected, close: true)
    }

    public func dispose() async {
        guard !disposed else { return }
        disposed = true
        await fail(PiClientError.disposed, close: true)
        snapshotListeners.removeAll()
        eventListeners.removeAll()
    }

    public func listSessions() async throws -> [SessionMetadata] {
        guard case .list(let sessions) = try await requestResult(.list) else {
            throw PiClientError.protocolFailure("Unexpected list result")
        }
        return sessions
    }

    public func createSession(_ options: CreateCommandOptions) async throws -> SessionLease {
        guard case .create(let snapshot) = try await requestResult(.create(options)) else {
            throw PiClientError.protocolFailure("Unexpected create result")
        }
        sessionSnapshots[snapshot.id] = snapshot
        return try await reserveLease(sessionID: snapshot.id, mode: .exclusive, alreadyAttached: true)
    }

    public func acquireSession(_ id: String, mode: LeaseMode) async throws -> SessionLease {
        try await reserveLease(sessionID: id, mode: mode, alreadyAttached: false)
    }

    public func attachSession(_ id: String) async throws -> SessionLease { try await acquireSession(id, mode: .shared) }

    public func subscribeSnapshots(_ listener: @escaping @Sendable (ServerSnapshot) -> Void) -> UUID {
        let id = UUID()
        snapshotListeners[id] = listener
        return id
    }
    public func subscribeEvents(_ listener: @escaping @Sendable (ServerEvent) -> Void) -> UUID {
        let id = UUID()
        eventListeners[id] = listener
        return id
    }
    public func unsubscribe(_ id: UUID) {
        snapshotListeners[id] = nil
        eventListeners[id] = nil
    }

    fileprivate func command(sessionID: String, command: Command) async throws -> SessionSnapshot {
        guard leaseIsActive(sessionID) else { throw PiClientError.detached }
        let result = try await requestResult(command)
        let snapshot: SessionSnapshot
        switch result {
        case .prompt(let value), .steer(let value), .abort(let value), .setModel(let value), .setThinking(let value):
            snapshot = value
        default: throw PiClientError.protocolFailure("Unexpected session result")
        }
        sessionSnapshots[sessionID] = snapshot
        return snapshot
    }

    fileprivate func release(sessionID: String, leaseID: UUID, explicit: Bool) async throws {
        guard var book = leases[sessionID] else { return }
        let wasExclusive = book.exclusive == leaseID
        let wasShared = book.shared.contains(leaseID)
        guard wasExclusive || wasShared else { return }
        let isFinal =
            (wasExclusive && book.shared.isEmpty) || (wasShared && book.exclusive == nil && book.shared.count == 1)
        guard isFinal, book.attached, stateValue == .connected else {
            removeLease(leaseID, from: &book)
            if book.exclusive == nil && book.shared.isEmpty && !book.attached {
                leases[sessionID] = nil
            } else {
                leases[sessionID] = book
            }
            return
        }

        let operation: DetachmentOperation
        if let existing = book.detachment {
            operation = existing
        } else {
            let token = UUID()
            let task = Task { try await self.performDetachment(sessionID: sessionID, token: token) }
            operation = DetachmentOperation(token: token, task: task)
            book.detachment = operation
            leases[sessionID] = book
        }
        do {
            try await operation.task.value
            guard var current = leases[sessionID] else { return }
            removeLease(leaseID, from: &current)
            if current.exclusive == nil && current.shared.isEmpty && !current.attached && current.attachment == nil {
                leases[sessionID] = nil
            } else {
                leases[sessionID] = current
            }
        } catch {
            if !explicit, var current = leases[sessionID] {
                removeLease(leaseID, from: &current)
                leases[sessionID] = current
                detachOrphanedAttachment(sessionID)
            }
            throw error
        }
    }

    private func reserveLease(sessionID: String, mode: LeaseMode, alreadyAttached: Bool) async throws -> SessionLease {
        try Task.checkCancellation()
        let id = UUID()
        var book = leases[sessionID] ?? LeaseBook()
        switch mode {
        case .exclusive: guard book.exclusive == nil, book.shared.isEmpty else { throw PiClientError.ownership }
        case .shared: guard book.exclusive == nil else { throw PiClientError.ownership }
        }
        if mode == .exclusive { book.exclusive = id } else { book.shared.insert(id) }
        if alreadyAttached { book.attached = true }
        leases[sessionID] = book

        do {
            if !alreadyAttached { try await ensureAttached(sessionID, leaseID: id) }
            try Task.checkCancellation()
            return SessionLease(id: id, sessionID: sessionID, mode: mode, client: self)
        } catch {
            if var current = leases[sessionID] {
                removeLease(id, from: &current)
                let needsOrphanDetachment =
                    current.exclusive == nil && current.shared.isEmpty && current.attached && current.attachment == nil
                if current.exclusive == nil && current.shared.isEmpty && !current.attached && current.attachment == nil
                {
                    leases[sessionID] = nil
                } else {
                    leases[sessionID] = current
                }
                if needsOrphanDetachment { detachOrphanedAttachment(sessionID) }
            }
            throw error
        }
    }

    private func ensureAttached(_ sessionID: String, leaseID: UUID) async throws {
        guard var book = leases[sessionID] else { throw PiClientError.detached }
        if book.attached, book.detachment == nil { return }
        let operationToken: UUID
        if let existing = book.attachment {
            operationToken = existing.token
        } else {
            let token = UUID()
            let task = Task { try await self.performAttachment(sessionID: sessionID, token: token) }
            let operation = AttachmentOperation(token: token, task: task)
            operationToken = token
            book.attachment = operation
            leases[sessionID] = book
            Task { await self.observeAttachment(sessionID: sessionID, operation: operation) }
        }
        try await waitForAttachment(sessionID: sessionID, operationToken: operationToken, leaseID: leaseID)
    }

    private func waitForAttachment(sessionID: String, operationToken: UUID, leaseID: UUID) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                guard var book = leases[sessionID], var operation = book.attachment,
                    operation.token == operationToken
                else {
                    if leases[sessionID]?.attached == true {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: PiClientError.detached)
                    }
                    return
                }
                operation.waiters[leaseID] = continuation
                book.attachment = operation
                leases[sessionID] = book
            }
        } onCancel: {
            Task { await self.cancelAttachmentWaiter(sessionID, operationToken: operationToken, leaseID: leaseID) }
        }
    }

    private func cancelAttachmentWaiter(_ sessionID: String, operationToken: UUID, leaseID: UUID) {
        guard var book = leases[sessionID], var operation = book.attachment,
            operation.token == operationToken,
            let waiter = operation.waiters.removeValue(forKey: leaseID)
        else { return }
        removeLease(leaseID, from: &book)
        book.attachment = operation
        leases[sessionID] = book
        waiter.resume(throwing: CancellationError())
    }

    private func observeAttachment(sessionID: String, operation: AttachmentOperation) async {
        do {
            completeAttachment(sessionID, token: operation.token, result: .success(try await operation.task.value))
        } catch {
            completeAttachment(sessionID, token: operation.token, result: .failure(error))
        }
    }

    private func completeAttachment(
        _ sessionID: String,
        token: UUID,
        result: Result<SessionSnapshot, Error>
    ) {
        guard var book = leases[sessionID], let operation = book.attachment, operation.token == token else { return }
        book.attachment = nil
        switch result {
        case .success(let snapshot):
            sessionSnapshots[sessionID] = snapshot
            book.attached = true
            leases[sessionID] = book
        case .failure:
            if book.exclusive == nil && book.shared.isEmpty && !book.attached {
                leases[sessionID] = nil
            } else {
                leases[sessionID] = book
            }
        }
        operation.waiters.values.forEach { $0.resume(with: result.map { _ in () }) }
        if case .success = result, book.exclusive == nil, book.shared.isEmpty {
            detachOrphanedAttachment(sessionID)
        }
    }

    private func performAttachment(sessionID: String, token: UUID) async throws -> SessionSnapshot {
        if let detachment = leases[sessionID]?.detachment { try? await detachment.task.value }
        guard let operation = leases[sessionID]?.attachment, operation.token == token else {
            throw PiClientError.detached
        }
        if leases[sessionID]?.attached == true {
            guard let snapshot = sessionSnapshots[sessionID] else { throw PiClientError.detached }
            return snapshot
        }
        guard case .attach(let snapshot) = try await requestResult(.attach(sessionID: sessionID)) else {
            throw PiClientError.protocolFailure("Unexpected attach result")
        }
        guard leases[sessionID]?.attachment?.token == token else { throw PiClientError.detached }
        return snapshot
    }

    private func detachOrphanedAttachment(_ sessionID: String) {
        guard var book = leases[sessionID], book.exclusive == nil, book.shared.isEmpty, book.attached,
            book.detachment == nil
        else { return }
        let token = UUID()
        let task = Task { try await self.performDetachment(sessionID: sessionID, token: token) }
        book.detachment = DetachmentOperation(token: token, task: task)
        leases[sessionID] = book
    }

    private func performDetachment(sessionID: String, token: UUID) async throws {
        do {
            guard case .detach = try await requestResult(.detach(sessionID: sessionID)) else {
                throw PiClientError.protocolFailure("Unexpected detach result")
            }
            guard var book = leases[sessionID], book.detachment?.token == token else { return }
            book.attached = false
            book.detachment = nil
            if book.exclusive == nil && book.shared.isEmpty && book.attachment == nil {
                leases[sessionID] = nil
            } else {
                leases[sessionID] = book
            }
        } catch {
            if leases[sessionID]?.detachment?.token == token { leases[sessionID]?.detachment = nil }
            throw error
        }
    }

    private func removeLease(_ id: UUID, from book: inout LeaseBook) {
        if book.exclusive == id { book.exclusive = nil }
        book.shared.remove(id)
    }

    private func leaseIsActive(_ id: String) -> Bool {
        guard let book = leases[id] else { return false }
        return book.exclusive != nil || !book.shared.isEmpty
    }

    private func requestResult(_ command: Command) async throws -> CommandResult {
        switch try await request(command) {
        case .failure(_, let error): throw PiClientError.server(error)
        case .success(_, let result):
            guard result.name == command.name else {
                throw PiClientError.protocolFailure(
                    "Response command \(result.name.rawValue) does not match \(command.name.rawValue)")
            }
            return result
        }
    }

    private func request(_ command: Command) async throws -> ResponseEnvelope {
        try Task.checkCancellation()
        guard stateValue == .connected, let transport else { throw PiClientError.disconnected }
        let id = UUID().uuidString
        let envelope = try RequestEnvelope(id: id, request: command)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    do { try await transport.send(try encodeClientMessage(.request(envelope), options: options)) } catch
                    {
                        self.reject(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func receive(_ data: Data, generation receivedGeneration: UInt64) {
        guard receivedGeneration == generation, let decoder else { return }
        do { for message in try decoder.push(data) { handle(message) } } catch {
            Task { await fail(error, close: true) }
        }
    }

    private func handle(_ message: ServerMessage) {
        if let handshake {
            self.handshake = nil
            handshake.timeoutTask.cancel()
            switch message {
            case .hello(let value):
                handshake.continuation.resume(returning: value.snapshot)
            case .helloError(let error):
                handshake.continuation.resume(throwing: PiClientError.server(error))
            default:
                handshake.continuation.resume(
                    throwing: PiClientError.protocolFailure("First server message was not hello")
                )
            }
            return
        }
        switch message {
        case .response(let response):
            guard let continuation = pending.removeValue(forKey: response.id) else {
                if cancelledRequestIDs.remove(response.id) != nil { return }
                Task {
                    await fail(
                        PiClientError.protocolFailure("Response has no matching request: \(response.id)"),
                        close: true
                    )
                }
                return
            }
            continuation.resume(returning: response)
        case .event(let event):
            reduce(event)
            eventListeners.values.forEach { $0(event) }
        default: Task { await fail(PiClientError.protocolFailure("Late hello"), close: true) }
        }
    }

    private func reduce(_ event: ServerEvent) {
        switch event {
        case .serverSnapshot(let snapshot):
            if snapshotValue == nil || snapshot.revision >= snapshotValue!.revision {
                snapshotValue = snapshot
                snapshotListeners.values.forEach { $0(snapshot) }
            }
        case .sessionSnapshot(let snapshot):
            if sessionSnapshots[snapshot.id] == nil || snapshot.revision >= sessionSnapshots[snapshot.id]!.revision {
                sessionSnapshots[snapshot.id] = snapshot
            }
        case .sessionRemoved(let id):
            sessionSnapshots[id] = nil
            leases[id] = nil
        case .sessionProgress: break
        }
    }

    private func closed(generation receivedGeneration: UInt64, error: Error?) async {
        guard receivedGeneration == generation else { return }
        await fail(error ?? PiClientError.disconnected, close: false)
    }
    private func reject(id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func cancelRequest(id: String) async {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        guard cancelledRequestIDs.count < Self.maximumCancelledRequestIDs else {
            await fail(
                PiClientError.protocolFailure(
                    "Cancelled request tracking limit exceeded"
                ),
                close: true
            )
            return
        }
        cancelledRequestIDs.insert(id)
    }

    private func fail(_ error: Error, close: Bool) async {
        generation &+= 1
        stateValue = .disconnected
        snapshotValue = nil
        sessionSnapshots.removeAll()
        let attachmentWaiters = leases.values.flatMap { book -> [CheckedContinuation<Void, Error>] in
            guard let attachment = book.attachment else { return [] }
            return Array(attachment.waiters.values)
        }
        leases.removeAll()
        attachmentWaiters.forEach { $0.resume(throwing: error) }
        let currentHandshake = handshake
        handshake = nil
        currentHandshake?.timeoutTask.cancel()
        currentHandshake?.continuation.resume(throwing: error)
        let current = pending
        pending.removeAll()
        cancelledRequestIDs.removeAll()
        current.values.forEach { $0.resume(throwing: error) }
        if close {
            let value = transport
            transport = nil
            await value?.close()
        }
        decoder = nil
    }
}

public actor SessionLease {
    public let id: UUID
    public let sessionID: String
    public let mode: LeaseMode
    private let client: PiClient
    private var active = true

    fileprivate init(id: UUID, sessionID: String, mode: LeaseMode, client: PiClient) {
        self.id = id
        self.sessionID = sessionID
        self.mode = mode
        self.client = client
    }
    public func prompt(_ text: String) async throws -> SessionSnapshot {
        try available()
        return try await client.command(sessionID: sessionID, command: .prompt(sessionID: sessionID, text: text))
    }
    public func steer(_ text: String) async throws -> SessionSnapshot {
        try available()
        return try await client.command(sessionID: sessionID, command: .steer(sessionID: sessionID, text: text))
    }
    public func abort() async throws -> SessionSnapshot {
        try available()
        return try await client.command(sessionID: sessionID, command: .abort(sessionID: sessionID))
    }
    public func setModel(_ value: ModelReference) async throws -> SessionSnapshot {
        try available()
        return try await client.command(sessionID: sessionID, command: .setModel(sessionID: sessionID, model: value))
    }
    public func setThinking(_ value: ThinkingLevel) async throws -> SessionSnapshot {
        try available()
        return try await client.command(
            sessionID: sessionID, command: .setThinking(sessionID: sessionID, thinkingLevel: value))
    }
    public func detach() async throws {
        try available()
        active = false
        do { try await client.release(sessionID: sessionID, leaseID: id, explicit: true) } catch {
            active = true
            throw error
        }
    }
    public func dispose() async throws {
        guard active else { return }
        active = false
        try await client.release(sessionID: sessionID, leaseID: id, explicit: false)
    }
    private func available() throws { guard active else { throw PiClientError.detached } }
}
