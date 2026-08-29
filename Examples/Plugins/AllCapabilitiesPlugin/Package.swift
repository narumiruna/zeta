// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AllCapabilitiesPlugin",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Zeta", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "AllCapabilitiesPlugin",
            dependencies: [
                .product(name: "ZetaPluginAPI", package: "zeta"),
                .product(name: "ZetaPluginSDK", package: "zeta"),
            ]
        )
    ]
)
