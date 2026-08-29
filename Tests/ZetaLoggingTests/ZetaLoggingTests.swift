import Darwin
import XCTest
import ZetaLogging

final class ZetaLoggingTests: XCTestCase {
    func testLoggerForwardsStructuredEntriesToItsSink() {
        let sink = RecordingLogSink()
        let logger = ZetaLogger(sink: sink)

        logger.debug("starting", metadata: ["mode": "rpc"])

        XCTAssertEqual(
            sink.entries(),
            [LogEntry(level: .debug, message: "starting", metadata: ["mode": "rpc"])]
        )
    }

    func testDefaultLoggerWritesStructuredEntriesToStandardError() throws {
        let output = try captureStandardError {
            let logger = ZetaLogger(label: "works.earendil.zeta.test", minimumLevel: .debug)
            logger.debug("starting", metadata: ["mode": "rpc"])
        }

        XCTAssertTrue(output.contains("debug works.earendil.zeta.test:"))
        XCTAssertTrue(output.contains("mode=rpc"))
        XCTAssertTrue(output.contains("starting"))
    }

    func testEnvironmentSelectsMinimumLevelWithoutChangingDefault() {
        XCTAssertEqual(ZetaLoggingConfiguration.minimumLevel(environment: [:]), .warning)
        XCTAssertEqual(
            ZetaLoggingConfiguration.minimumLevel(environment: ["ZETA_LOG_LEVEL": "DEBUG"]),
            .debug
        )
        XCTAssertEqual(
            ZetaLoggingConfiguration.minimumLevel(environment: ["ZETA_LOG_LEVEL": "invalid"]),
            .warning
        )
    }
}

private func captureStandardError(_ body: () -> Void) throws -> String {
    let pipe = Pipe()
    let savedStandardError = dup(STDERR_FILENO)
    guard savedStandardError >= 0 else { throw POSIXError(.EBADF) }

    fflush(stderr)
    guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0 else {
        close(savedStandardError)
        throw POSIXError(.EBADF)
    }

    body()
    fflush(stderr)
    guard dup2(savedStandardError, STDERR_FILENO) >= 0 else {
        close(savedStandardError)
        throw POSIXError(.EBADF)
    }
    close(savedStandardError)
    try pipe.fileHandleForWriting.close()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

private struct LogEntry: Equatable {
    let level: ZetaLogLevel
    let message: String
    let metadata: [String: String]
}

private final class RecordingLogSink: ZetaLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LogEntry] = []

    func log(level: ZetaLogLevel, message: String, metadata: [String: String]) {
        lock.lock()
        recorded.append(LogEntry(level: level, message: message, metadata: metadata))
        lock.unlock()
    }

    func entries() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
