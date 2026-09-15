// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MistypeIME",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MistypeIME", targets: ["MistypeIME"]),
        .executable(name: "MistypeSourceTool", targets: ["MistypeSourceTool"]),
    ],
    targets: [
        .target(name: "MistypeCore"),
        .executableTarget(name: "MistypeIME", dependencies: ["MistypeCore"]),
        .executableTarget(name: "MistypeSourceTool"),
        .testTarget(name: "MistypeCoreTests", dependencies: ["MistypeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
