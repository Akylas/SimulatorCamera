// swift-tools-version: 5.9
// SimulatorCamera — root SwiftPM manifest
// Users add this repo as a dependency and import SimulatorCameraClient.

import PackageDescription

let package = Package(
    name: "SimulatorCamera",
    platforms: [
        .iOS(.v13),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SimulatorCameraClient",
            targets: ["SimulatorCameraClient"]
        ),
    ],
    targets: [
        .target(
            name: "SimulatorCameraClient",
            path: "Sources/SimulatorCameraClient"
        ),
        .testTarget(
            name: "SimulatorCameraClientTests",
            dependencies: ["SimulatorCameraClient"],
            path: "Tests/SimulatorCameraClientTests"
        ),
    ]
)
