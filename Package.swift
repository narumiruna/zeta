// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Zeta",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZetaCore", targets: ["ZetaCore"]),
        .library(name: "ZetaTelemetry", targets: ["ZetaTelemetry"]),
        .library(name: "ZetaAI", targets: ["ZetaAI"]),
        .library(name: "ZetaAuth", targets: ["ZetaAuth"]),
        .library(name: "ZetaBedrock", targets: ["ZetaBedrock"]),
        .library(name: "ZetaAgent", targets: ["ZetaAgent"]),
        .library(name: "ZetaCompaction", targets: ["ZetaCompaction"]),
        .library(name: "ZetaExport", targets: ["ZetaExport"]),
        .library(name: "ZetaEvals", targets: ["ZetaEvals"]),
        .library(name: "ZetaMigration", targets: ["ZetaMigration"]),
        .library(name: "ZetaSessions", targets: ["ZetaSessions"]),
        .library(name: "ZetaSearch", targets: ["ZetaSearch"]),
        .library(name: "ZetaHarnessSessions", targets: ["ZetaHarnessSessions"]),
        .library(name: "ZetaSessionFormat", targets: ["ZetaSessionFormat"]),
        .library(name: "ZetaSessionSQLite", targets: ["ZetaSessionSQLite"]),
        .library(name: "ZetaProtocol", targets: ["ZetaProtocol"]),
        .library(name: "ZetaClient", targets: ["ZetaClient"]),
        .library(name: "ZetaServer", targets: ["ZetaServer"]),
        .library(name: "ZetaUnixTransport", targets: ["ZetaUnixTransport"]),
        .library(name: "ZetaConfig", targets: ["ZetaConfig"]),
        .library(name: "ZetaResources", targets: ["ZetaResources"]),
        .library(name: "ZetaPackages", targets: ["ZetaPackages"]),
        .library(name: "ZetaModes", targets: ["ZetaModes"]),
        .library(name: "ZetaTools", targets: ["ZetaTools"]),
        .library(name: "ZetaPluginAPI", targets: ["ZetaPluginAPI"]),
        .library(name: "ZetaPluginSDK", targets: ["ZetaPluginSDK"]),
        .library(name: "ZetaTerminal", targets: ["ZetaTerminal"]),
        .library(name: "ZetaTUI", targets: ["ZetaTUI"]),
        .library(name: "ZetaTestSupport", targets: ["ZetaTestSupport"]),
        .library(name: "ZetaCLI", targets: ["ZetaCLI"]),
        .executable(name: "zeta", targets: ["ZetaExecutable"]),
        .executable(name: "pi", targets: ["PiExecutable"]),
        .executable(name: "zeta-benchmarks", targets: ["ZetaBenchmarks"]),
        .executable(name: "zeta-interop-client", targets: ["ZetaInteropClient"]),
        .executable(name: "zeta-interop-server", targets: ["ZetaInteropServer"]),
        .executable(name: "zeta-interop-sqlite", targets: ["ZetaInteropSQLite"]),
    ],
    targets: [
        .target(name: "ZetaCore"),
        .target(name: "ZetaTelemetry", dependencies: ["ZetaCore"]),
        .target(name: "ZetaAuth"),
        .target(name: "ZetaBedrock", dependencies: ["ZetaAI", "ZetaAuth", "ZetaCore"]),
        .target(
            name: "ZetaAI",
            dependencies: ["ZetaCore", "ZetaTelemetry"],
            resources: [.process("Resources")]
        ),
        .target(name: "ZetaAgent", dependencies: ["ZetaAI", "ZetaCore"]),
        .target(name: "ZetaCompaction", dependencies: ["ZetaAI"]),
        .target(name: "ZetaExport"),
        .target(name: "ZetaEvals"),
        .target(name: "ZetaMigration"),
        .target(name: "ZetaSessions", dependencies: ["ZetaAI", "ZetaCore"]),
        .target(name: "ZetaSearch"),
        .target(name: "ZetaHarnessSessions", dependencies: ["ZetaCore"]),
        .target(name: "ZetaSessionFormat", dependencies: ["ZetaCore"]),
        .target(name: "ZetaSessionSQLite", dependencies: ["ZetaCore"]),
        .target(name: "ZetaProtocol", dependencies: ["ZetaCore"]),
        .target(name: "ZetaClient", dependencies: ["ZetaProtocol"]),
        .target(name: "ZetaServer", dependencies: ["ZetaProtocol"]),
        .target(name: "ZetaUnixTransport", dependencies: ["ZetaClient", "ZetaServer"]),
        .target(name: "ZetaConfig"),
        .target(name: "ZetaResources"),
        .target(name: "ZetaPackages"),
        .target(name: "ZetaModes", dependencies: ["ZetaCore"]),
        .target(name: "ZetaTools"),
        .target(name: "ZetaPluginAPI"),
        .target(name: "ZetaPluginSDK", dependencies: ["ZetaPluginAPI"]),
        .target(name: "ZetaTerminal"),
        .target(name: "ZetaTUI", dependencies: ["ZetaTerminal"]),
        .target(name: "ZetaTestSupport"),
        .target(
            name: "ZetaCLI",
            dependencies: [
                "ZetaAI", "ZetaAgent", "ZetaCompaction", "ZetaConfig", "ZetaCore", "ZetaExport",
                "ZetaAuth", "ZetaBedrock", "ZetaMigration", "ZetaModes", "ZetaPackages", "ZetaPluginAPI",
                "ZetaResources", "ZetaSessions", "ZetaSessionSQLite", "ZetaTerminal", "ZetaTools", "ZetaTUI",
                "ZetaClient", "ZetaServer", "ZetaUnixTransport",
            ]
        ),
        .executableTarget(name: "ZetaExecutable", dependencies: ["ZetaCLI"]),
        .executableTarget(name: "PiExecutable", dependencies: ["ZetaCLI"]),
        .executableTarget(
            name: "ZetaBenchmarks",
            dependencies: [
                "ZetaAI", "ZetaCore", "ZetaPluginAPI", "ZetaProtocol", "ZetaSearch",
                "ZetaSessionSQLite", "ZetaTUI", "ZetaTerminal",
            ]
        ),
        .executableTarget(
            name: "ZetaInteropClient",
            dependencies: ["ZetaClient", "ZetaUnixTransport"]
        ),
        .executableTarget(
            name: "ZetaInteropServer",
            dependencies: ["ZetaProtocol", "ZetaServer", "ZetaUnixTransport"]
        ),
        .executableTarget(
            name: "ZetaInteropSQLite",
            dependencies: ["ZetaCore", "ZetaSessionSQLite"]
        ),
        .testTarget(name: "ZetaCoreTests", dependencies: ["ZetaCore"]),
        .testTarget(name: "ZetaTelemetryTests", dependencies: ["ZetaTelemetry"]),
        .testTarget(name: "ZetaProtocolTests", dependencies: ["ZetaProtocol", "ZetaCore"]),
        .testTarget(name: "ZetaClientTests", dependencies: ["ZetaClient", "ZetaServer", "ZetaProtocol"]),
        .testTarget(name: "ZetaServerTests", dependencies: ["ZetaServer", "ZetaProtocol"]),
        .testTarget(
            name: "ZetaUnixTransportTests",
            dependencies: ["ZetaUnixTransport", "ZetaClient"]
        ),
        .testTarget(name: "ZetaAITests", dependencies: ["ZetaAI", "ZetaCore"]),
        .testTarget(name: "ZetaAuthTests", dependencies: ["ZetaAuth"]),
        .testTarget(name: "ZetaBedrockTests", dependencies: ["ZetaBedrock"]),
        .testTarget(name: "ZetaAgentTests", dependencies: ["ZetaAgent", "ZetaAI", "ZetaCore"]),
        .testTarget(name: "ZetaCompactionTests", dependencies: ["ZetaCompaction", "ZetaAI"]),
        .testTarget(name: "ZetaExportTests", dependencies: ["ZetaExport"]),
        .testTarget(name: "ZetaEvalsTests", dependencies: ["ZetaEvals"]),
        .testTarget(name: "ZetaMigrationTests", dependencies: ["ZetaMigration"]),
        .testTarget(name: "ZetaSessionsTests", dependencies: ["ZetaSessions", "ZetaAI"]),
        .testTarget(name: "ZetaSearchTests", dependencies: ["ZetaSearch"]),
        .testTarget(name: "ZetaHarnessSessionsTests", dependencies: ["ZetaHarnessSessions", "ZetaCore"]),
        .testTarget(name: "ZetaSessionFormatTests", dependencies: ["ZetaSessionFormat"]),
        .testTarget(name: "ZetaSessionSQLiteTests", dependencies: ["ZetaSessionSQLite", "ZetaCore"]),
        .testTarget(name: "ZetaConfigTests", dependencies: ["ZetaConfig"]),
        .testTarget(name: "ZetaResourcesTests", dependencies: ["ZetaResources"]),
        .testTarget(name: "ZetaPackagesTests", dependencies: ["ZetaPackages"]),
        .testTarget(name: "ZetaModesTests", dependencies: ["ZetaModes"]),
        .testTarget(name: "ZetaToolsTests", dependencies: ["ZetaTools"]),
        .testTarget(name: "ZetaPluginAPITests", dependencies: ["ZetaPluginAPI"]),
        .testTarget(name: "ZetaPluginSDKTests", dependencies: ["ZetaPluginSDK", "ZetaPluginAPI"]),
        .testTarget(name: "ZetaTUITests", dependencies: ["ZetaTUI", "ZetaTerminal"]),
        .testTarget(name: "ZetaTestSupportTests", dependencies: ["ZetaTestSupport"]),
        .testTarget(
            name: "ZetaCLITests",
            dependencies: [
                "ZetaCLI", "ZetaAgent", "ZetaAI", "ZetaCompaction", "ZetaCore", "ZetaModes",
                "ZetaSessionFormat", "ZetaSessions",
            ]
        ),
        .testTarget(
            name: "ZetaCompatibilityTests",
            dependencies: [
                "ZetaAI", "ZetaCore", "ZetaHarnessSessions", "ZetaModes", "ZetaProtocol",
                "ZetaSessions", "ZetaSessionSQLite", "ZetaTUI", "ZetaTools",
            ]
        ),
    ]
)
