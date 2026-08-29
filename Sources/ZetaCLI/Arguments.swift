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
        var result = CLIArguments()
        var index = 0
        var options = true
        func requireValue(_ flag: String) throws -> String {
            index += 1
            guard index < values.count else { throw CLIArgumentError.missingValue(flag) }
            return values[index]
        }
        while index < values.count {
            let value = values[index]
            if options && value == "--" {
                options = false
                index += 1
                continue
            }
            if options && value.hasPrefix("--") {
                let parts = value.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let flag = String(parts[0])
                let attached = parts.count > 1 ? String(parts[1]) : nil
                func argument() throws -> String {
                    if let attached { return attached }
                    return try requireValue("--\(flag)")
                }
                switch flag {
                case "help": result.help = true
                case "version": result.version = true
                case "print": result.print = true
                case "mode":
                    guard let mode = CLIMode(rawValue: try argument()) else {
                        throw CLIArgumentError.invalidValue("--mode")
                    }
                    result.mode = mode
                case "list-models": result.listModels = attached ?? ""
                case "provider": result.provider = try argument()
                case "model":
                    let value = try argument()
                    if let separator = value.lastIndex(of: ":"),
                        let level = ThinkingLevel(rawValue: String(value[value.index(after: separator)...]))
                    {
                        result.model = String(value[..<separator])
                        result.thinking = level
                        result.thinkingSpecified = true
                    } else {
                        result.model = value
                    }
                case "api-key": result.apiKey = try argument()
                case "thinking":
                    guard let level = ThinkingLevel(rawValue: try argument()) else {
                        throw CLIArgumentError.invalidValue("--thinking")
                    }
                    result.thinking = level
                    result.thinkingSpecified = true
                case "no-session": result.noSession = true
                case "continue": result.continueSession = true
                case "resume": result.resume = true
                case "session": result.session = try argument()
                case "session-id": result.sessionID = try argument()
                case "fork": result.fork = try argument()
                case "session-dir": result.sessionDirectory = try argument()
                case "name": result.name = try argument()
                case "tools": result.tools = Set(try argument().split(separator: ",").map(String.init))
                case "exclude-tools":
                    result.excludedTools.formUnion(try argument().split(separator: ",").map(String.init))
                case "no-builtin-tools": result.noBuiltinTools = true
                case "no-tools": result.noTools = true
                case "approve": result.approve = true
                case "no-approve": result.approve = false
                case "offline": result.offline = true
                default: throw CLIArgumentError.invalidValue("--\(flag)")
                }
            } else if options && value.hasPrefix("-") {
                switch value {
                case "-h": result.help = true
                case "-v": result.version = true
                case "-p": result.print = true
                case "-c": result.continueSession = true
                case "-r": result.resume = true
                case "-a": result.approve = true
                case "-na": result.approve = false
                case "-n": result.name = try requireValue("-n")
                case "-t": result.tools = Set(try requireValue("-t").split(separator: ",").map(String.init))
                case "-xt":
                    result.excludedTools.formUnion(try requireValue("-xt").split(separator: ",").map(String.init))
                case "-nt": result.noTools = true
                case "-nbt": result.noBuiltinTools = true
                default: throw CLIArgumentError.unknownShortFlag(value)
                }
            } else if options && value.hasPrefix("@") {
                result.files.append(String(value.dropFirst()))
            } else {
                result.messages.append(value)
            }
            index += 1
        }
        try result.validate()
        return result
    }

    public func effectiveMode(stdinIsTTY: Bool, stdoutIsTTY: Bool) -> CLIMode {
        if let mode { return mode }
        if print || !stdinIsTTY || !stdoutIsTTY { return .print }
        return .interactive
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
