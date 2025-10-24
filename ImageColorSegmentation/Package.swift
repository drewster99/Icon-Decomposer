// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageColorSegmentation",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ImageColorSegmentation",
            targets: ["ImageColorSegmentation"]
        ),
        .executable(
            name: "Demo",
            targets: ["Demo"]
        ),
        .executable(
            name: "ImageColorSegmentationDemo",
            targets: ["ImageColorSegmentationDemo"]
        ),
        .executable(
            name: "BasicUsageExample",
            targets: ["BasicUsageExample"]
        ),
    ],
    targets: [
        .target(
            name: "ImageColorSegmentation",
            dependencies: [],
            resources: [
                .process("SLIC.metal"),
                .process("KMeans.metal")
            ]
        ),
        .executableTarget(
            name: "Demo",
            dependencies: []
        ),
        .executableTarget(
            name: "ImageColorSegmentationDemo",
            dependencies: ["ImageColorSegmentation"]
        ),
        .executableTarget(
            name: "BasicUsageExample",
            dependencies: ["ImageColorSegmentation"],
            resources: [
                .copy("Resources/test-icon.png")
            ]
        ),
        .testTarget(
            name: "ImageColorSegmentationTests",
            dependencies: ["ImageColorSegmentation"]
        ),
    ]
)
