// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Saynori",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device Parakeet speech recognition (Core ML, runs on the Neural Engine).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        // Cactus Needle engine (C API) for on-device Whistle speech recognition.
        .target(name: "CNeedle", path: "Sources/CNeedle"),
        .executableTarget(
            name: "Saynori",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), "CNeedle"],
            path: "Sources/Saynori",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip", "-LVendor/needle"]),
                .linkedLibrary("needle"),
                .linkedLibrary("c++"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
