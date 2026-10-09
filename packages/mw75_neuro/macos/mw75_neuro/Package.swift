// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "mw75_neuro",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "mw75-neuro", targets: ["mw75_neuro"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "mw75_neuro",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth")
            ]
        )
    ]
)
