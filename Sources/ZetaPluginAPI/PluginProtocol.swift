import Foundation

public let zetaPluginProtocolVersion = 1

public struct PluginManifest: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let protocolVersion: Int
    public let executable: String
    public let capabilities: Set<PluginCapability>

    public init(
        name: String, version: String, protocolVersion: Int = zetaPluginProtocolVersion, executable: String,
        capabilities: Set<PluginCapability>
    ) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
        self.executable = executable
        self.capabilities = capabilities
    }

    public func validate() throws {
        guard protocolVersion == zetaPluginProtocolVersion else {
            throw PluginError.unsupportedProtocol(protocolVersion)
        }
        guard !name.isEmpty, !version.isEmpty, !executable.isEmpty else { throw PluginError.invalidManifest }
    }
}

public enum PluginCapability: String, Codable, Sendable, CaseIterable {
    case tools
    case commands
    case flags
    case events
    case providers
    case authentication
    case resources
    case sessions
    case userInterface = "ui"
}

public enum PluginError: Error, LocalizedError, Equatable {
    case invalidManifest
    case unsupportedProtocol(Int)
    case untrusted
    case timedOut
    case crashed(Int32)
    case malformedMessage
    case staleRuntime
    case unsupportedCapability(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "Plugin manifest is invalid"
        case .unsupportedProtocol(let version): "Unsupported plugin protocol version: \(version)"
        case .untrusted: "Plugin execution requires project trust"
        case .timedOut: "Plugin request timed out"
        case .crashed(let code): "Plugin process exited with code \(code)"
        case .malformedMessage: "Plugin sent a malformed message"
        case .staleRuntime: "Plugin callback belongs to a stale runtime"
        case .unsupportedCapability(let value): "Unsupported plugin capability: \(value)"
        }
    }
}

public struct PluginEnvelope: Codable, Sendable, Equatable {
    public let id: String?
    public let type: String
    public let generation: UInt64
    public let method: String?
    public let payload: Data?
    public let error: String?

    public init(
        id: String? = nil, type: String, generation: UInt64, method: String? = nil, payload: Data? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.type = type
        self.generation = generation
        self.method = method
        self.payload = payload
        self.error = error
    }
}

public struct PluginRegistration: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case tool
        case command
        case flag
        case event
        case provider
        case authentication
        case resource
        case session
        case ui
    }
    public let kind: Kind
    public let name: String
    public let callback: String
    public let schema: Data?

    public init(
        kind: Kind,
        name: String,
        callback: String,
        schema: Data? = nil
    ) {
        self.kind = kind
        self.name = name
        self.callback = callback
        self.schema = schema
    }
}

public actor PluginHost {
    private static let activeLock = NSLock()
    private nonisolated(unsafe) static var activeProcesses: [Int32: Process] = [:]

    public static func terminateActiveProcesses() {
        let processes = activeLock.withLock { Array(activeProcesses.values) }
        for process in processes where process.isRunning { process.terminate() }
    }

    public struct Configuration: Sendable {
        public var requestTimeout: Duration = .seconds(30)
        public var maximumRecordBytes = 16 * 1_024 * 1_024
        public init() {}
    }

    private let configuration: Configuration
    private(set) var generation: UInt64 = 0
    private(set) var registrations: [PluginRegistration] = []
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var requestActive = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func start(manifest: PluginManifest, baseDirectory: URL, trusted: Bool) async throws {
        guard trusted else { throw PluginError.untrusted }
        try manifest.validate()
        await stop()
        generation &+= 1
        registrations = []
        let process = Process()
        let executable =
            manifest.executable.hasPrefix("/")
            ? URL(fileURLWithPath: manifest.executable).standardizedFileURL
            : baseDirectory.appendingPathComponent(manifest.executable)
                .standardizedFileURL
        process.executableURL = executable
        process.currentDirectoryURL = baseDirectory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ZETA_PLUGIN_PROTOCOL": String(zetaPluginProtocolVersion),
            "ZETA_PLUGIN_GENERATION": String(generation),
        ]) { _, value in value }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        Self.activeLock.withLock { Self.activeProcesses[process.processIdentifier] = process }
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        do {
            let response = try await request(method: "initialize", payload: try JSONEncoder().encode(manifest))
            let proposed = try JSONDecoder().decode([PluginRegistration].self, from: response)
            try validate(proposed, capabilities: manifest.capabilities)
            registrations = proposed
        } catch {
            await stop()
            registrations = []
            throw error
        }
    }

    public func currentRegistrations() -> [PluginRegistration] { registrations }

    public func request(method: String, payload: Data? = nil) async throws -> Data {
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        guard let process, process.isRunning, let input, let output else {
            throw PluginError.crashed(process?.terminationStatus ?? -1)
        }
        let id = UUID().uuidString
        let envelope = PluginEnvelope(id: id, type: "request", generation: generation, method: method, payload: payload)
        var encoded = try JSONEncoder().encode(envelope)
        guard encoded.count <= configuration.maximumRecordBytes else { throw PluginError.malformedMessage }
        encoded.append(0x0A)
        try input.write(contentsOf: encoded)
        let line: Data
        do {
            line = try await PluginLineRead.read(
                from: output,
                maximumBytes: configuration.maximumRecordBytes,
                timeout: configuration.requestTimeout
            )
        } catch {
            await stop()
            throw error
        }
        let response = try JSONDecoder().decode(PluginEnvelope.self, from: line)
        guard response.id == id, response.generation == generation, response.type == "response" else {
            throw PluginError.staleRuntime
        }
        if let error = response.error { throw PluginError.unsupportedCapability(error) }
        return response.payload ?? Data()
    }

    public func stop() async {
        generation &+= 1
        registrations = []
        let process = self.process
        let input = self.input
        let output = self.output
        self.process = nil
        self.input = nil
        self.output = nil
        try? input?.close()
        try? output?.close()
        if let process {
            Self.activeLock.withLock { Self.activeProcesses[process.processIdentifier] = nil }
        }
        if let process, process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(100))
            if process.isRunning { process.interrupt() }
        }
    }

    private func acquireRequestSlot() async {
        if !requestActive {
            requestActive = true
            return
        }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    private func releaseRequestSlot() {
        if requestWaiters.isEmpty {
            requestActive = false
        } else {
            requestWaiters.removeFirst().resume()
        }
    }

    private func validate(_ values: [PluginRegistration], capabilities: Set<PluginCapability>) throws {
        var names = Set<String>()
        for value in values {
            guard !value.name.isEmpty, !value.callback.isEmpty,
                names.insert("\(value.kind.rawValue):\(value.name)").inserted
            else {
                throw PluginError.invalidManifest
            }
            let required: PluginCapability =
                switch value.kind {
                case .tool: .tools
                case .command: .commands
                case .flag: .flags
                case .event: .events
                case .provider: .providers
                case .authentication: .authentication
                case .resource: .resources
                case .session: .sessions
                case .ui: .userInterface
                }
            guard capabilities.contains(required) else { throw PluginError.unsupportedCapability(required.rawValue) }
        }
    }

}

private final class PluginLineRead: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let maximumBytes: Int
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var settled = false

    private init(handle: FileHandle, maximumBytes: Int) {
        self.handle = handle
        self.maximumBytes = maximumBytes
    }

    static func read(
        from handle: FileHandle,
        maximumBytes: Int,
        timeout: Duration
    ) async throws -> Data {
        let operation = PluginLineRead(handle: handle, maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
    }

    private func start(
        continuation: CheckedContinuation<Data, Error>,
        timeout: Duration
    ) {
        lock.withLock { self.continuation = continuation }
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else {
                self.finish(.failure(PluginError.crashed(-1)))
                return
            }
            self.consume(data)
        }
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(.failure(PluginError.timedOut))
        }
    }

    private func consume(_ data: Data) {
        let result: Result<Data, Error>? = lock.withLock {
            guard !settled else { return nil }
            buffer.append(data)
            if buffer.count > maximumBytes {
                return .failure(PluginError.malformedMessage)
            }
            guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
            var line = Data(buffer[..<newline])
            if line.last == 0x0D { line.removeLast() }
            return .success(line)
        }
        if let result { finish(result) }
    }

    fileprivate func finish(_ result: Result<Data, Error>) {
        let callback: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            let value = continuation
            continuation = nil
            return value
        }
        guard let callback else { return }
        handle.readabilityHandler = nil
        callback.resume(with: result)
    }
}
