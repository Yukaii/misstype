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
var dependencies: [Package.Dependency] = []
#if os(macOS)
// Sparkle is macOS-only and declared here so Linux never resolves it.
dependencies += [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
]
products += [
    .executable(name: "MistypeIME", targets: ["MistypeIME"]),
    .executable(name: "MistypeSourceTool", targets: ["MistypeSourceTool"]),
    .executable(name: "MistypeInstaller", targets: ["MistypeInstaller"]),
]
targets += [
    .executableTarget(
        name: "MistypeIME",
        dependencies: ["MistypeCore", .product(name: "Sparkle", package: "Sparkle")],
        // The packaged bundle carries Sparkle.framework in Contents/Frameworks.
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .executableTarget(name: "MistypeSourceTool"),
    // Double-clickable installer shipped in the DMG (see docs/release.md).
    .executableTarget(name: "MistypeInstaller"),
]
#endif

let package = Package(
    name: "MistypeIME",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
