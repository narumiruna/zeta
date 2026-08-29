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
