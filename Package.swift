// swift-tools-version: 6.0
import PackageDescription

// MistypeCore (decoder + InputSession) builds everywhere Swift does; the
// InputMethodKit adapter and the Carbon source tool are macOS-only.
// MistypeCAPI (C ABI over MistypeCore) and CMistype (C header) build on all platforms.
var products: [Product] = [
    .library(name: "MistypeCAPI", type: .dynamic, targets: ["MistypeCAPI"]),
]
var targets: [Target] = [
    .target(name: "MistypeCore"),
    .target(name: "CMistype"),
    .target(name: "MistypeCAPI", dependencies: ["MistypeCore", "CMistype"]),
    .testTarget(name: "MistypeCoreTests", dependencies: ["MistypeCore"],
                path: "tests/MistypeCoreTests"),
]
#if os(macOS)
products += [
    .executable(name: "MistypeIME", targets: ["MistypeIME"]),
    .executable(name: "MistypeSourceTool", targets: ["MistypeSourceTool"]),
]
targets += [
    .executableTarget(name: "MistypeIME", dependencies: ["MistypeCore"]),
    .executableTarget(name: "MistypeSourceTool"),
]
#endif

let package = Package(
    name: "MistypeIME",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
