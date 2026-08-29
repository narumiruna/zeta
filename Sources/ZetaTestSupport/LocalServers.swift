import Darwin
import Foundation

public final class LocalHTTPServer: @unchecked Sendable {
    public let url: URL
    private let descriptor: Int32
    private let response: Data
    private let lock = NSLock()
    private var stopped = false
    private var requests: [Data] = []

    public init(response: Data) throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse))
        )
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketDescriptor, 8) == 0 else {
            close(socketDescriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(socketDescriptor, $0, &length)
            }
        }
        self.response = response
        descriptor = socketDescriptor
        url = URL(string: "http://127.0.0.1:\(Int(UInt16(bigEndian: actual.sin_port)))")!
        DispatchQueue.global().async { [weak self] in self?.acceptLoop() }
    }

    public convenience init(
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data()
    ) throws {
        var fields = headers
        fields["Content-Length"] = String(body.count)
        fields["Connection"] = "close"
        let reason = status == 200 ? "OK" : "Error"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        for key in fields.keys.sorted() {
            response.append(Data("\(key): \(fields[key]!)\r\n".utf8))
        }
        response.append(Data("\r\n".utf8))
        response.append(body)
        try self.init(response: response)
    }

    public static func serverSentEvents(_ records: [String]) throws -> LocalHTTPServer {
        let body = Data(records.map { "data: \($0)\n\n" }.joined().utf8)
        return try LocalHTTPServer(
            headers: ["Content-Type": "text/event-stream"],
            body: body
        )
    }

    public func capturedRequests() -> [Data] {
        lock.withLock { requests }
    }

    public func stop() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldClose {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    deinit { stop() }

    private func acceptLoop() {
        while !lock.withLock({ stopped }) {
            let client = accept(descriptor, nil, nil)
            if client < 0 { return }
            var request = Data()
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let count = Darwin.read(client, &bytes, bytes.count)
                if count <= 0 { break }
                request.append(contentsOf: bytes.prefix(count))
                if request.count > 1_048_576 { break }
            }
            lock.withLock { requests.append(request) }
            response.withUnsafeBytes { pointer in
                var sent = 0
                while sent < response.count {
                    let count = Darwin.write(client, pointer.baseAddress!.advanced(by: sent), response.count - sent)
                    if count <= 0 { break }
                    sent += count
                }
            }
            shutdown(client, SHUT_RDWR)
            close(client)
        }
    }
}

public actor ScriptedSocket {
    private var inbound: [Data]
    private var outbound: [Data] = []

    public init(inbound: [Data]) { self.inbound = inbound }
    public func send(_ data: Data) { outbound.append(Data(data)) }
    public func receive() -> Data? { inbound.isEmpty ? nil : inbound.removeFirst() }
    public func sent() -> [Data] { outbound }
}
