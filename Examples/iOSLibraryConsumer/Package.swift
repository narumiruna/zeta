// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ZetaIOSLibraryConsumer",
    platforms: [.iOS(.v17)],
    products: [
        .library(
            name: "ZetaIOSLibraryConsumer",
            targets: ["ZetaIOSLibraryConsumer"]
        )
    ],
    dependencies: [
        .package(name: "Zeta", path: "../..")
    ],
    targets: [
        .target(
            name: "ZetaIOSLibraryConsumer",
            dependencies: [
                .product(name: "ZetaAI", package: "Zeta"),
                .product(name: "ZetaAgent", package: "Zeta"),
            ]
        ),
        .testTarget(
            name: "ZetaIOSLibraryConsumerTests",
            dependencies: [
                "ZetaIOSLibraryConsumer",
                .product(name: "ZetaAI", package: "Zeta"),
                .product(name: "ZetaAgent", package: "Zeta"),
            ]
        ),
    ]
)
