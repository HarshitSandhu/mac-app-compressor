// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "mac-app-compressor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Compressor", targets: ["Compressor"])
    ],
    targets: [
        .executableTarget(
            name: "Compressor"
        ),
        .testTarget(
            name: "CompressorTests",
            dependencies: ["Compressor"]
        )
    ]
)
