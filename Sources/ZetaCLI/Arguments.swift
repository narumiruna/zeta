import ArgumentParser
import Foundation
import ZetaAI

public enum CLIMode: String, Sendable { case interactive, print, json, rpc }

public struct CLIArguments: Sendable {
    public var mode: CLIMode?
    public var print = false
    public var help = false
    public var version = false
    public var listModels: String?
    public var provider: String?
    public var model: String?
    public var apiKey: String?
    public var thinking: ThinkingLevel = .off
    public var thinkingSpecified = false
    public var noSession = false
    public var continueSession = false
    public var resume = false
    public var session: String?
    public var sessionID: String?
    public var fork: String?
    public var sessionDirectory: String?
    public var name: String?
    public var tools: Set<String>?
    public var excludedTools: Set<String> = []
    public var noBuiltinTools = false
    public var noTools = false
    public var approve: Bool?
    public var offline = false
    public var files: [String] = []
    public var messages: [String] = []
    public var extensionFlags: [String: String?] = [:]

    public static func parse(_ values: [String]) throws -> CLIArguments {
        let preprocessed = CLIArgumentPreprocessor.process(values)
        let parsed: ParsedCLIArguments
        do {
            parsed = try SwiftArgumentParserAdapter().parse(preprocessed.values)
        } catch {
            throw normalizeParserError(error)
        }

        var result = CLIArguments()
        result.mode = try parsed.mode.map { value in
            guard let mode = CLIMode(rawValue: value) else {
                throw CLIArgumentError.invalidValue("--mode")
            }
            return mode
        }
        result.print = parsed.print
        result.help = preprocessed.help
        result.version = preprocessed.version
        result.listModels = preprocessed.listModels
        result.provider = parsed.provider
        result.apiKey = parsed.apiKey
        result.noSession = parsed.noSession
        result.continueSession = parsed.continueSession
        result.resume = parsed.resume
        result.session = parsed.session
        result.sessionID = parsed.sessionID
        result.fork = parsed.fork
        result.sessionDirectory = parsed.sessionDirectory
        result.name = parsed.name
        result.tools = parsed.tools.map(commaSeparatedSet)
        result.excludedTools = Set(parsed.excludedTools.flatMap(commaSeparatedValues))
        result.noBuiltinTools = parsed.noBuiltinTools
        result.noTools = parsed.noTools
        result.approve = parsed.approve
        result.offline = parsed.offline
        result.files = preprocessed.files
        result.messages = parsed.inputs

        for selection in preprocessed.thinkingSelections {
            switch selection {
            case .model(let model):
                result.model = model
                if let separator = model.lastIndex(of: ":"),
                    let level = ThinkingLevel(rawValue: String(model[model.index(after: separator)...]))
                {
                    result.model = String(model[..<separator])
                    result.thinking = level
                    result.thinkingSpecified = true
                }
            case .thinking(let thinking):
                guard let level = ThinkingLevel(rawValue: thinking) else {
                    throw CLIArgumentError.invalidValue("--thinking")
                }
                result.thinking = level
                result.thinkingSpecified = true
            }
        }

        try result.validate()
        return result
    }

    public func effectiveMode(stdinIsTTY: Bool, stdoutIsTTY: Bool) -> CLIMode {
        if let mode { return mode }
        if print || !stdinIsTTY || !stdoutIsTTY { return .print }
        return .interactive
    }

    private static func commaSeparatedSet(_ value: String) -> Set<String> {
        Set(commaSeparatedValues(value))
    }

    private static func commaSeparatedValues(_ value: String) -> [String] {
        value.split(separator: ",").map(String.init)
    }

    private static func normalizeParserError(_ error: any Error) -> any Error {
        let message = ParsedCLIArguments.message(for: error)
        let marker = "Unknown option '"
        if message.hasPrefix(marker), let end = message.dropFirst(marker.count).firstIndex(of: "'") {
            let option = String(message.dropFirst(marker.count)[..<end])
            let name = option.split(separator: "=", maxSplits: 1).first.map(String.init) ?? option
            if name.hasPrefix("--") { return CLIArgumentError.invalidValue(name) }
            return CLIArgumentError.unknownShortFlag(name)
        }
        return CLIParserMessageError(message: message)
    }

    private func validate() throws {
        if fork != nil && (session != nil || sessionID != nil || continueSession || resume || noSession) {
            throw CLIArgumentError.conflict("--fork")
        }
        if sessionID != nil && (session != nil || continueSession || resume) {
            throw CLIArgumentError.conflict("--session-id")
        }
        if let sessionID,
            sessionID.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$"#,
                options: .regularExpression
            ) == nil
        {
            throw CLIArgumentError.invalidValue("--session-id")
        }
        if noTools && tools != nil { throw CLIArgumentError.conflict("--no-tools and --tools") }
    }
}

private protocol CLIOptionParser {
    func parse(_ values: [String]) throws -> ParsedCLIArguments
}

private struct SwiftArgumentParserAdapter: CLIOptionParser {
    func parse(_ values: [String]) throws -> ParsedCLIArguments {
        try ParsedCLIArguments.parse(values)
    }
}

private struct ParsedCLIArguments: ParsableArguments {
    @Flag(name: .shortAndLong) var print = false
    @Option(name: .long, parsing: .unconditional) var mode: String?
    @Option(name: .long, parsing: .unconditional) var provider: String?
    @Option(name: .long, parsing: .unconditional) var model: String?
    @Option(name: .customLong("api-key"), parsing: .unconditional) var apiKey: String?
    @Option(name: .long, parsing: .unconditional) var thinking: String?
    @Flag(name: .customLong("no-session")) var noSession = false
    @Flag(name: [.customShort("c"), .customLong("continue")]) var continueSession = false
    @Flag(name: .shortAndLong) var resume = false
    @Option(name: .long, parsing: .unconditional) var session: String?
    @Option(name: .customLong("session-id"), parsing: .unconditional) var sessionID: String?
    @Option(name: .long, parsing: .unconditional) var fork: String?
    @Option(name: .customLong("session-dir"), parsing: .unconditional) var sessionDirectory: String?
    @Option(name: .long, parsing: .unconditional) var name: String?
    @Option(name: .long, parsing: .unconditional) var tools: String?
    @Option(
        name: .customLong("exclude-tools"),
        parsing: .unconditionalSingleValue
    ) var excludedTools: [String] = []
    @Flag(name: [
        .customLong("nbt", withSingleDash: true),
        .customLong("no-builtin-tools"),
    ]) var noBuiltinTools = false
    @Flag(name: [
        .customLong("nt", withSingleDash: true),
        .customLong("no-tools"),
    ]) var noTools = false
    @Flag(
        name: .customLong("approve"),
        inversion: .prefixedNo,
        exclusivity: .chooseLast
    ) var approve: Bool?
    @Flag(name: .long) var offline = false
    @Argument(parsing: .remaining) var inputs: [String] = []
}

private struct PreprocessedCLIArguments {
    var values: [String]
    var help = false
    var version = false
    var listModels: String?
    var files: [String] = []
    var thinkingSelections: [CLIThinkingSelection] = []
}

private enum CLIThinkingSelection {
    case model(String)
    case thinking(String)
}

private enum CLIArgumentPreprocessor {
    private static let valueOptions: Set<String> = [
        "--mode", "--provider", "--model", "--api-key", "--thinking", "--session",
        "--session-id", "--fork", "--session-dir", "--name", "--tools", "--exclude-tools",
        "-n", "-t", "-xt",
    ]

    static func process(_ values: [String]) -> PreprocessedCLIArguments {
        var result = PreprocessedCLIArguments(values: [])
        var index = 0
        while index < values.count {
            let value = values[index]
            if value == "--" {
                result.values.append(contentsOf: values[index...])
                break
            }
            if valueOptions.contains(value), values.indices.contains(index + 1) {
                let optionValue = values[index + 1]
                result.values.append(normalizedOptionName(value))
                result.values.append(optionValue)
                recordThinkingSelection(name: value, value: optionValue, in: &result)
                index += 2
                continue
            }
            let longParts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = longParts.first.map(String.init) ?? value
            if longParts.count == 2 {
                recordThinkingSelection(name: name, value: String(longParts[1]), in: &result)
            }
            switch value {
            case "-h":
                result.help = true
            case "-v":
                result.version = true
            case "-a":
                result.values.append("--approve")
            case "-na":
                result.values.append("--no-approve")
            default:
                switch name {
                case "--help":
                    result.help = true
                case "--version":
                    result.version = true
                case "--list-models":
                    result.listModels = longParts.count == 2 ? String(longParts[1]) : ""
                default:
                    if value.hasPrefix("@") {
                        result.files.append(String(value.dropFirst()))
                    } else {
                        result.values.append(value)
                    }
                }
            }
            index += 1
        }
        return result
    }

    private static func normalizedOptionName(_ name: String) -> String {
        switch name {
        case "-n": "--name"
        case "-t": "--tools"
        case "-xt": "--exclude-tools"
        default: name
        }
    }

    private static func recordThinkingSelection(
        name: String,
        value: String,
        in result: inout PreprocessedCLIArguments
    ) {
        switch name {
        case "--model": result.thinkingSelections.append(.model(value))
        case "--thinking": result.thinkingSelections.append(.thinking(value))
        default: break
        }
    }
}

private struct CLIParserMessageError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

public enum CLIArgumentError: Error, LocalizedError, Sendable {
    case missingValue(String)
    case invalidValue(String)
    case unknownShortFlag(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .missingValue(let flag): "Missing value for \(flag)"
        case .invalidValue(let flag): "Invalid value for \(flag)"
        case .unknownShortFlag(let flag): "Unknown short flag: \(flag)"
        case .conflict(let value): "Conflicting options: \(value)"
        }
    }
}
