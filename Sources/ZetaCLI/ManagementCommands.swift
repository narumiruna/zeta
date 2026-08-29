import Foundation
import ZetaAI
import ZetaConfig
import ZetaMigration
import ZetaPackages

struct PackageCommandLocation: Sendable, Equatable {
    let root: URL
    let trusted: Bool
}

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
                let locations = migrationLocations(arguments: arguments)
                let report = try PiMigrator(
                    source: locations.source,
                    destination: locations.destination
                ).migrate()
                let data = try JSONEncoder().encode(report)
                print(String(decoding: data, as: UTF8.self))
                return 0
            }
            let location = packageCommandLocation(
                arguments: arguments,
                workingDirectory: URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath
                ),
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            let manager = try ResourcePackageManager(root: location.root)
            switch command {
            case "install":
                guard let source = packageCommandSource(arguments) else {
                    throw CLIArgumentError.missingValue("install source")
                }
                try await manager.install(
                    PackageSource(source),
                    trusted: location.trusted
                )
                print("Installed \(source)")
            case "remove", "uninstall":
                guard let rawSource = packageCommandSource(arguments) else {
                    throw CLIArgumentError.missingValue("remove source")
                }
                let source = try PackageSource(rawSource)
                try await manager.remove(
                    source.identifier,
                    trusted: location.trusted
                )
                print("Removed \(source.identifier)")
            case "update":
                try await manager.updateAll(trusted: location.trusted)
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
            let ready = await CLIProviderAuthenticationResolver.isReady(
                provider: provider,
                store: store,
                environment: ProcessInfo.processInfo.environment
            )
            if arguments.contains("--json") {
                let value: [String: Any] = [
                    "provider": provider,
                    "ready": ready,
                    "credentialType": stored.map { $0.kind as Any } ?? NSNull(),
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
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let deadline = try minimumExpiryDeadline(
                nowMilliseconds: now,
                minimumMilliseconds: minimum
            )
            guard case .oauth(let access, _, let expires, _)? = await store.read(provider: provider),
                expires > deadline
            else {
                return 1
            }
            print(access)
            return 0
        default:
            throw CLIArgumentError.invalidValue("auth \(command)")
        }
    }

    static func durationMilliseconds(_ value: String) throws -> Int64 {
        let units: [(suffix: String, multiplier: Int64)] = [
            ("ms", 1),
            ("s", 1_000),
            ("m", 60_000),
            ("h", 3_600_000),
            ("d", 86_400_000),
        ]
        let matched = units.first { value.hasSuffix($0.suffix) }
        let numberText = matched.map { String(value.dropLast($0.suffix.count)) } ?? value
        guard !numberText.isEmpty,
            numberText.allSatisfy(\.isNumber),
            let number = Int64(numberText),
            number >= 0
        else {
            throw CLIArgumentError.invalidValue("--min-expiry")
        }
        let result = number.multipliedReportingOverflow(by: matched?.multiplier ?? 1)
        guard !result.overflow else {
            throw CLIArgumentError.invalidValue("--min-expiry")
        }
        return result.partialValue
    }

    static func minimumExpiryDeadline(
        nowMilliseconds: Int64,
        minimumMilliseconds: Int64
    ) throws -> Int64 {
        guard minimumMilliseconds >= 0 else {
            throw CLIArgumentError.invalidValue("--min-expiry")
        }
        let deadline = nowMilliseconds.addingReportingOverflow(minimumMilliseconds)
        guard !deadline.overflow else {
            throw CLIArgumentError.invalidValue("--min-expiry")
        }
        return deadline.partialValue
    }

    static func migrationLocations(
        arguments: [String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (source: URL, destination: URL) {
        let paths = ZetaPaths(
            home: home,
            workingDirectory: workingDirectory,
            environment: environment
        )
        return (
            URL(
                fileURLWithPath: value(after: "--source", in: arguments)
                    ?? home.appendingPathComponent(".pi/agent").path
            ),
            URL(
                fileURLWithPath: value(after: "--destination", in: arguments)
                    ?? paths.agentDirectory.path
            )
        )
    }

    static func packageCommandLocation(
        arguments: [String],
        workingDirectory: URL,
        home: URL
    ) -> PackageCommandLocation {
        let local = arguments.contains("-l") || arguments.contains("--local")
        let root =
            local
            ? workingDirectory.standardizedFileURL.appendingPathComponent(".pi/packages")
            : home.standardizedFileURL.appendingPathComponent(".pi/agent/packages")
        let approved = arguments.contains("--approve") || arguments.contains("-a")
        let denied = arguments.contains("--no-approve") || arguments.contains("-na")
        return PackageCommandLocation(root: root, trusted: !local || (approved && !denied))
    }

    static func packageCommandSource(_ arguments: [String]) -> String? {
        arguments.dropFirst().first { !$0.hasPrefix("-") }
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
