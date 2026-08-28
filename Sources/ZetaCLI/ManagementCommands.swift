import Foundation
import ZetaAI
import ZetaConfig
import ZetaMigration
import ZetaPackages

extension ZetaCLI {
    static func runManagementCommand(
        _ arguments: [String]
    ) async -> Int32? {
        guard let command = arguments.first,
            ["install", "remove", "uninstall", "update", "list", "config", "auth", "migrate"]
                .contains(command)
        else {
            return nil
        }
        do {
            if command == "auth" {
                return try await runAuth(Array(arguments.dropFirst()))
            }
            if command == "migrate" {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let source = URL(
                    fileURLWithPath: value(after: "--source", in: arguments)
                        ?? home.appendingPathComponent(".pi/agent").path
                )
                let destination = URL(
                    fileURLWithPath: value(after: "--destination", in: arguments)
                        ?? home.appendingPathComponent(".zeta/agent").path
                )
                let report = try PiMigrator(source: source, destination: destination).migrate()
                let data = try JSONEncoder().encode(report)
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
            let local = arguments.contains("-l")
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let root =
                local
                ? cwd.appendingPathComponent(".pi/packages")
                : FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".pi/agent/packages")
            let manager = try ResourcePackageManager(root: root)
            switch command {
            case "install":
                guard arguments.count >= 2 else {
                    throw CLIArgumentError.missingValue("install source")
                }
                try await manager.install(
                    PackageSource(arguments[1]),
                    trusted: !local || arguments.contains("--approve")
                )
                print("Installed \(arguments[1])")
            case "remove", "uninstall":
                guard arguments.count >= 2 else {
                    throw CLIArgumentError.missingValue("remove source")
                }
                let source = try PackageSource(arguments[1])
                try await manager.remove(
                    source.identifier,
                    trusted: !local || arguments.contains("--approve")
                )
                print("Removed \(source.identifier)")
            case "update":
                try await manager.updateAll(
                    trusted: !local || arguments.contains("--approve")
                )
                print("Updated unpinned resource packages")
            case "list", "config":
                for package in await manager.list() {
                    print(
                        "\(package.source)\t\(package.pinned ? "pinned" : "tracking")\t\(package.directory)"
                    )
                }
            default:
                break
            }
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("\(error.localizedDescription)\n".utf8)
            )
            return 1
        }
    }

    private static func runAuth(_ arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first else {
            throw CLIArgumentError.missingValue("auth command")
        }
        let provider =
            value(after: "--provider", in: arguments)
            ?? value(after: "-p", in: arguments)
        guard let provider else {
            throw CLIArgumentError.missingValue("--provider")
        }
        let paths = ZetaPaths(
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let store = try AuthStore(url: paths.auth)
        switch command {
        case "check":
            let stored = await store.read(provider: provider)
            let variables = BuiltinProviderFactory.environmentVariables[provider] ?? []
            let environmentReady = variables.contains {
                ProcessInfo.processInfo.environment[$0]?.isEmpty == false
            }
            let ready = stored != nil || environmentReady
            if arguments.contains("--json") {
                let value: [String: Any] = [
                    "provider": provider,
                    "ready": ready,
                    "credentialType": stored?.kind as Any,
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.sortedKeys]
                )
                print(String(decoding: data, as: UTF8.self))
            } else {
                print("\(provider): \(ready ? "ready" : "not configured")")
            }
            return ready ? 0 : 1
        case "print-api-key":
            let key = try await store.resolveAPIKey(
                provider: provider,
                environment: ProcessInfo.processInfo.environment,
                fallbackVariables: BuiltinProviderFactory.environmentVariables[provider] ?? []
            )
            guard let key else { return 1 }
            print(key)
            return 0
        case "print-bearer-token":
            let minimum =
                try value(after: "--min-expiry", in: arguments)
                .map(durationMilliseconds) ?? 30 * 60 * 1_000
            guard case .oauth(let access, _, let expires, _)? = await store.read(provider: provider),
                expires > Int64(Date().timeIntervalSince1970 * 1_000) + minimum
            else {
                return 1
            }
            print(access)
            return 0
        default:
            throw CLIArgumentError.invalidValue("auth \(command)")
        }
    }

    private static func durationMilliseconds(_ value: String) throws -> Int64 {
        let unit = value.last
        let numberText = unit?.isNumber == true ? value : String(value.dropLast())
        guard let number = Int64(numberText), number >= 0 else {
            throw CLIArgumentError.invalidValue("--min-expiry")
        }
        switch unit {
        case "s": return number * 1_000
        case "m": return number * 60 * 1_000
        case "h": return number * 60 * 60 * 1_000
        case "d": return number * 24 * 60 * 60 * 1_000
        case _ where unit?.isNumber == true: return number
        default: throw CLIArgumentError.invalidValue("--min-expiry")
        }
    }

    private static func value(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }
}
