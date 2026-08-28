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
        if let timeout, (!timeout.isFinite || timeout <= 0 || timeout * 1_000 > Double(Int32.max)) {
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
        try process.run()
        _ = setpgid(process.processIdentifier, process.processIdentifier)

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ShellRace.self) { group in
                group.addTask {
                    var data = Data()
                    for try await byte in pipe.fileHandleForReading.bytes {
                        data.append(byte)
                        if data.count % 4_096 == 0, let text = String(data: data, encoding: .utf8) {
                            onUpdate?(text)
                        }
                    }
                    process.waitUntilExit()
                    return .completed(data, process.terminationStatus)
                }
                if let timeout {
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        return .timeout
                    }
                }
                guard let first = try await group.next() else {
                    throw FileToolError.processFailed("Command did not produce a result")
                }
                group.cancelAll()
                switch first {
                case .timeout:
                    Self.terminateProcessTree(process)
                    try? pipe.fileHandleForReading.close()
                    throw FileToolError.timedOut
                case .completed(let data, let status):
                    let full = String(decoding: data, as: UTF8.self)
                    let truncated = Truncation.tail(full)
                    var outputFile: URL?
                    if truncated.truncated {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("zeta-shell-\(UUID().uuidString).log")
                        try data.write(to: url, options: .atomic)
                        outputFile = url
                    }
                    return ShellResult(
                        output: truncated.content,
                        exitCode: status,
                        truncated: truncated.truncated,
                        fullOutputFile: outputFile
                    )
                }
            }
        } onCancel: {
            Self.terminateProcessTree(process)
        }
    }

    private static func terminateProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        if kill(-process.processIdentifier, SIGTERM) != 0 {
            process.terminate()
        }
        usleep(100_000)
        if process.isRunning {
            kill(-process.processIdentifier, SIGKILL)
            process.interrupt()
        }
    }
}

private enum ShellRace: Sendable {
    case completed(Data, Int32)
    case timeout
}
