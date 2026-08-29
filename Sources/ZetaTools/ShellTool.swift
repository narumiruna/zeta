import Foundation

public struct ShellResult: Sendable, Equatable {
    public let output: String
    public let exitCode: Int32
    public let truncated: Bool
    public let fullOutputFile: URL?
}

public struct ShellTool: Sendable {
    public let workingDirectory: URL
    public let shell: String

    public init(workingDirectory: URL, shell: String = "/bin/bash") {
        self.workingDirectory = workingDirectory
        self.shell = shell
    }

    public func run(
        command: String,
        timeout: TimeInterval? = nil,
        environment: [String: String] = [:],
        onUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> ShellResult {
        if let timeout, !timeout.isFinite || timeout <= 0 || timeout * 1_000 > Double(Int32.max) {
            throw FileToolError.invalidEdit("timeout must be positive and fit signed 32-bit milliseconds")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, explicit in explicit }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let spoolURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeta-shell-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: spoolURL.path, contents: nil),
            let spool = try? FileHandle(forWritingTo: spoolURL)
        else {
            throw FileToolError.processFailed("Could not create shell output spool")
        }
        var preserveSpool = false
        defer {
            try? spool.close()
            if !preserveSpool { try? FileManager.default.removeItem(at: spoolURL) }
        }

        try process.run()
        ToolProcessLifecycle.prepare(process)

        let capture: (ShellCapture, Int32)
        do {
            capture = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: ShellRace.self) { group in
                    group.addTask {
                        var capture = ShellCapture()
                        var chunk = Data()
                        var lastUpdateBytes = 0
                        var nextUpdate = ContinuousClock.now
                        defer { try? spool.close() }
                        for try await byte in pipe.fileHandleForReading.bytes {
                            chunk.append(byte)
                            guard chunk.count >= 16 * 1_024 else { continue }
                            try spool.write(contentsOf: chunk)
                            capture.append(chunk)
                            chunk.removeAll(keepingCapacity: true)
                            if let onUpdate, ContinuousClock.now >= nextUpdate {
                                onUpdate(capture.output)
                                lastUpdateBytes = capture.totalBytes
                                nextUpdate = ContinuousClock.now.advanced(by: .milliseconds(100))
                            }
                        }
                        if !chunk.isEmpty {
                            try spool.write(contentsOf: chunk)
                            capture.append(chunk)
                        }
                        if let onUpdate, capture.totalBytes != lastUpdateBytes {
                            onUpdate(capture.output)
                        }
                        let status = try await Self.waitForExit(process)
                        return .completed(capture, status)
                    }
                    if let timeout {
                        group.addTask {
                            try await Task.sleep(for: .seconds(timeout))
                            return .timedOut
                        }
                    }
                    guard let first = try await group.next() else {
                        throw FileToolError.processFailed("Command did not produce a result")
                    }
                    group.cancelAll()
                    switch first {
                    case .timedOut:
                        ToolProcessLifecycle.terminate(process, closing: [pipe.fileHandleForReading])
                        throw FileToolError.timedOut
                    case .completed(let capture, let status):
                        return (capture, status)
                    }
                }
            } onCancel: {
                ToolProcessLifecycle.terminate(process, closing: [pipe.fileHandleForReading])
            }
        } catch {
            ToolProcessLifecycle.terminate(process, closing: [pipe.fileHandleForReading])
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        let truncated = capture.0.truncated
        preserveSpool = truncated
        return ShellResult(
            output: capture.0.output,
            exitCode: capture.1,
            truncated: truncated,
            fullOutputFile: truncated ? spoolURL : nil
        )
    }

    private static func waitForExit(_ process: Process) async throws -> Int32 {
        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        return process.terminationStatus
    }
}

private struct ShellCapture: Sendable {
    private static let retainedBytes = defaultMaximumBytes * 2
    private var tail = Data()
    private var tailStartsAtLineBoundary = true
    private var newlineCount = 0
    private var lastByte: UInt8?
    private(set) var totalBytes = 0

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        totalBytes += data.count
        newlineCount += data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        lastByte = data.last
        tail.append(data)
        guard tail.count > Self.retainedBytes else { return }
        let removed = tail.count - Self.retainedBytes
        tailStartsAtLineBoundary = tail[tail.index(tail.startIndex, offsetBy: removed - 1)] == 0x0A
        tail.removeFirst(removed)
    }

    var truncated: Bool {
        totalBytes > defaultMaximumBytes || totalLines > defaultMaximumLines
    }

    var output: String {
        var snapshot = tail
        if !tailStartsAtLineBoundary, let newline = snapshot.firstIndex(of: 0x0A) {
            snapshot.removeSubrange(snapshot.startIndex...newline)
        }
        return Truncation.tail(String(decoding: snapshot, as: UTF8.self)).content
    }

    private var totalLines: Int {
        guard totalBytes > 0 else { return 0 }
        return newlineCount + (lastByte == 0x0A ? 0 : 1)
    }
}

private enum ShellRace: Sendable {
    case completed(ShellCapture, Int32)
    case timedOut
}
