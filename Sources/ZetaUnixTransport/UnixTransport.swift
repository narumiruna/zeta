import Darwin
import Foundation
import ZetaClient
import ZetaServer

public enum UnixTransportError: Error, LocalizedError, Sendable {
    case pathTooLong(Int)
    case invalidExistingPath
    case system(String, Int32)
    case pendingBytesExceeded
    case closed

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let count): "Unix socket path is \(count) UTF-8 bytes; macOS supports at most 103"
        case .invalidExistingPath: "Unix socket path exists and is not a socket"
        case .system(let operation, let code): "\(operation) failed: \(String(cString: strerror(code)))"
        case .pendingBytesExceeded: "Unix transport pending-byte limit exceeded"
        case .closed: "Unix transport is closed"
        }
    }
}

private func setNoSigPipe(_ descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
            socklen_t(MemoryLayout<Int32>.size)) == 0
    else { throw UnixTransportError.system("setsockopt(SO_NOSIGPIPE)", errno) }
}

private func socketAddress(_ path: String) throws -> (sockaddr_un, socklen_t) {
    let bytes = Array(path.utf8)
    guard bytes.count <= 103 else { throw UnixTransportError.pathTooLong(bytes.count) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { target in
        target.initializeMemory(as: UInt8.self, repeating: 0)
        target.copyBytes(from: bytes)
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    return (address, length)
}

public final class UnixByteTransport: ByteTransport, @unchecked Sendable {
    private let descriptor: Int32
    private let handlers: ByteTransportHandlers
    private let maximumPendingBytes: Int
    private let queue = DispatchQueue(label: "zeta.unix.client.write")
    private let lock = NSLock()
    private var pendingBytes = 0
    private var closed = false
    private var readSource: DispatchSourceRead?

    public init(path: String, maximumPendingBytes: Int = 64 * 1_024 * 1_024, handlers: ByteTransportHandlers) throws {
        self.handlers = handlers
        self.maximumPendingBytes = maximumPendingBytes
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixTransportError.system("socket", errno) }
        do {
            try setNoSigPipe(descriptor)
            var (address, length) = try socketAddress(path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) }
            }
            guard result == 0 else { throw UnixTransportError.system("connect", errno) }
            startReading()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public func send(_ bytes: Data) async throws {
        let copy = Data(bytes)
        try lock.withLock {
            guard !closed else { throw UnixTransportError.closed }
            guard pendingBytes + copy.count <= maximumPendingBytes else {
                throw UnixTransportError.pendingBytesExceeded
            }
            pendingBytes += copy.count
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: UnixTransportError.closed)
                    return
                }
                defer { self.lock.withLock { self.pendingBytes -= copy.count } }
                do {
                    try Self.writeAll(copy, to: self.descriptor)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                    self.fail(error)
                }
            }
        }
    }

    public func close() async { closeSync(notify: false) }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(self.descriptor, &bytes, bytes.count)
            if count > 0 {
                self.handlers.onData(Data(bytes.prefix(count)))
            } else if count == 0 {
                self.closeSync(notify: true)
            } else if errno != EINTR && errno != EAGAIN {
                self.fail(UnixTransportError.system("read", errno))
            }
        }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source.resume()
        readSource = source
    }

    private func fail(_ error: Error) {
        handlers.onError(error)
        closeSync(notify: false)
    }
    private func closeSync(notify: Bool) {
        let shouldClose = lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        readSource?.cancel()
        readSource = nil
        if notify { handlers.onClose() }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw UnixTransportError.system("write", errno)
                }
            }
        }
    }
}

public func createUnixTransportFactory(path: String, maximumPendingBytes: Int = 64 * 1_024 * 1_024)
    -> ByteTransportFactory
{
    { handlers in try UnixByteTransport(path: path, maximumPendingBytes: maximumPendingBytes, handlers: handlers) }
}

public final class UnixServerConnection: ServerByteConnection, @unchecked Sendable {
    public let id = UUID().uuidString
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "zeta.unix.server.write")
    private let lock = NSLock()
    private var closed = false
    private var readSource: DispatchSourceRead?
    private var dataHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?

    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

    public func start(onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        dataHandler = onData
        closeHandler = onClose
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = Darwin.read(self.descriptor, &bytes, bytes.count)
            if count > 0 {
                self.dataHandler?(Data(bytes.prefix(count)))
            } else if count == 0 {
                self.closeSync(notify: true)
            } else if errno != EINTR && errno != EAGAIN {
                self.closeSync(notify: true)
            }
        }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source.resume()
        readSource = source
    }

    public func send(_ bytes: Data) async throws {
        let copy = Data(bytes)
        guard !lock.withLock({ closed }) else { throw UnixTransportError.closed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try copy.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let count = Darwin.write(
                                self.descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                            if count > 0 {
                                offset += count
                            } else if count < 0 && errno == EINTR {
                                continue
                            } else {
                                throw UnixTransportError.system("write", errno)
                            }
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                    self.closeSync(notify: true)
                }
            }
        }
    }

    public func close() async { closeSync(notify: false) }
    private func closeSync(notify: Bool) {
        let changed = lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        guard changed else { return }
        shutdown(descriptor, SHUT_RDWR)
        let source = readSource
        source?.cancel()
        readSource = nil
        if source == nil { Darwin.close(descriptor) }
        if notify { closeHandler?() }
    }
}

public final class UnixServerListener: @unchecked Sendable {
    public let path: String
    private let descriptor: Int32
    private var source: DispatchSourceRead?
    private let onConnection: @Sendable (UnixServerConnection) -> Void
    private let lock = NSLock()
    private var closed = false
    private var ownedDevice: dev_t = 0
    private var ownedInode: ino_t = 0

    public init(path: String, mode: mode_t = 0o600, onConnection: @escaping @Sendable (UnixServerConnection) -> Void)
        throws
    {
        self.path = path
        self.onConnection = onConnection
        _ = try socketAddress(path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            var existing = stat()
            guard lstat(path, &existing) == 0,
                existing.st_mode & S_IFMT == S_IFSOCK
            else {
                throw UnixTransportError.invalidExistingPath
            }
            if try Self.socketIsLive(path) {
                throw UnixTransportError.system("socket path is already in use", EADDRINUSE)
            }
            var current = stat()
            if lstat(path, &current) == 0,
                current.st_dev == existing.st_dev,
                current.st_ino == existing.st_ino
            {
                unlink(path)
            }
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let privatePath = directory.appendingPathComponent(
            ".p-\(UUID().uuidString.prefix(8))"
        ).path
        unlink(privatePath)
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw UnixTransportError.system("socket", errno) }
        descriptor = fileDescriptor
        do {
            try setNoSigPipe(fileDescriptor)
            var (address, length) = try socketAddress(privatePath)
            guard
                withUnsafePointer(
                    to: &address,
                    {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.bind(fileDescriptor, $0, length)
                        }
                    }
                ) == 0
            else {
                throw UnixTransportError.system("bind", errno)
            }
            guard listen(fileDescriptor, SOMAXCONN) == 0 else {
                throw UnixTransportError.system("listen", errno)
            }
            let flags = fcntl(fileDescriptor, F_GETFL)
            guard flags >= 0,
                fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
            else {
                throw UnixTransportError.system("nonblocking listener", errno)
            }
            guard chmod(privatePath, mode) == 0 else {
                throw UnixTransportError.system("chmod", errno)
            }
            guard link(privatePath, path) == 0 else {
                throw UnixTransportError.system("publish socket", errno)
            }
            unlink(privatePath)
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw UnixTransportError.system("lstat", errno)
            }
            ownedDevice = info.st_dev
            ownedInode = info.st_ino
        } catch {
            Darwin.close(fileDescriptor)
            unlink(privatePath)
            var published = stat()
            if lstat(path, &published) == 0,
                published.st_dev == ownedDevice,
                published.st_ino == ownedInode
            {
                unlink(path)
            }
            throw error
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: .global())
        source?.setEventHandler { [weak self] in self?.acceptReady() }
        source?.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source?.resume()
    }

    public func close() {
        let changed = lock.withLock {
            if closed { return false }
            closed = true
            return true
        }
        guard changed else { return }
        source?.cancel()
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == ownedDevice, info.st_ino == ownedInode { unlink(path) }
    }

    deinit { close() }

    private static func socketIsLive(_ path: String) throws -> Bool {
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw UnixTransportError.system("socket probe", errno) }
        defer { Darwin.close(probe) }
        try setNoSigPipe(probe)
        var (address, length) = try socketAddress(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, length)
            }
        }
        if result == 0 { return true }
        if errno == ECONNREFUSED || errno == ENOENT { return false }
        throw UnixTransportError.system("socket probe", errno)
    }

    private func acceptReady() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client >= 0 {
                do {
                    try setNoSigPipe(client)
                    onConnection(UnixServerConnection(descriptor: client))
                } catch {
                    Darwin.close(client)
                }
            } else if errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}
