import Foundation
import Logging

public enum ZetaLogLevel: String, Sendable, CaseIterable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical
}

public protocol ZetaLogSink: Sendable {
    func log(
        level: ZetaLogLevel,
        message: String,
        metadata: [String: String]
    )
}

public struct ZetaLogger: Sendable {
    private let sink: any ZetaLogSink

    public init(
        label: String,
        minimumLevel: ZetaLogLevel = ZetaLoggingConfiguration.minimumLevel()
    ) {
        sink = SwiftLogSink(label: label, minimumLevel: minimumLevel)
    }

    public init(sink: any ZetaLogSink) {
        self.sink = sink
    }

    public func trace(_ message: String, metadata: [String: String] = [:]) {
        sink.log(level: .trace, message: message, metadata: metadata)
    }

    public func debug(_ message: String, metadata: [String: String] = [:]) {
        sink.log(level: .debug, message: message, metadata: metadata)
    }

    public func info(_ message: String, metadata: [String: String] = [:]) {
        sink.log(level: .info, message: message, metadata: metadata)
    }

    public func notice(_ message: String, metadata: [String: String] = [:]) {
        sink.log(level: .notice, message: message, metadata: metadata)
    }

    public func warning(_ message: String, metadata: [String: String] = [:]) {
        sink.log(level: .warning, message: message, metadata: metadata)
    }

    public func error(_ message: String, metadata: [String: String] = [:]) {
        sink.log(level: .error, message: message, metadata: metadata)
    }

    public func critical(_ message: String, metadata: [String: String] = [:]) {
        sink.log(level: .critical, message: message, metadata: metadata)
    }
}

public enum ZetaLoggingConfiguration {
    public static func minimumLevel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ZetaLogLevel {
        environment["ZETA_LOG_LEVEL"]
            .flatMap { ZetaLogLevel(rawValue: $0.lowercased()) }
            ?? .warning
    }
}

private struct SwiftLogSink: ZetaLogSink {
    private let logger: Logger

    init(label: String, minimumLevel: ZetaLogLevel) {
        var logger = Logger(label: label) { label in
            StreamLogHandler.standardError(label: label)
        }
        logger.logLevel = minimumLevel.swiftLogLevel
        self.logger = logger
    }

    func log(
        level: ZetaLogLevel,
        message: String,
        metadata: [String: String]
    ) {
        logger.log(
            level: level.swiftLogLevel,
            Logger.Message(stringLiteral: message),
            metadata: metadata.mapValues(Logger.MetadataValue.string)
        )
    }
}

private extension ZetaLogLevel {
    var swiftLogLevel: Logger.Level {
        switch self {
        case .trace: .trace
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warning: .warning
        case .error: .error
        case .critical: .critical
        }
    }
}
