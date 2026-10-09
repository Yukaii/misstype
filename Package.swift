// swift-tools-version: 6.0
import PackageDescription

// MisstypeCore (decoder + InputSession) builds everywhere Swift does; the
// InputMethodKit adapter and the Carbon source tool are macOS-only.
// MisstypeCAPI (C ABI over MisstypeCore) and CMisstype (C header) build on all platforms.
var products: [Product] = [
    .library(name: "MisstypeCAPI", type: .dynamic, targets: ["MisstypeCAPI"]),
    .executable(name: "MisstypeWasm", targets: ["MisstypeWasm"]),
    // Product name keeps the binary `misstypectl`; the target directory differs
    // from MisstypeCtl by more than case (macOS file systems ignore case).
    .executable(name: "misstypectl", targets: ["MisstypeCtlTool"]),
]

var targets: [Target] = [
    .target(name: "MisstypeCore"),
    .target(name: "CMisstype"),
    .target(name: "MisstypeCAPI", dependencies: ["MisstypeCore", "CMisstype"]),
    .executableTarget(
        name: "MisstypeWasm",
        dependencies: ["MisstypeCore"]
    ),
    .target(name: "MisstypeCtl", dependencies: ["MisstypeCore"]),
    .executableTarget(name: "MisstypeCtlTool", dependencies: ["MisstypeCtl"]),
    .testTarget(name: "MisstypeCtlTests", dependencies: ["MisstypeCtl", "MisstypeCore"],
                path: "tests/MisstypeCtlTests"),
    .testTarget(name: "MisstypeCoreTests", dependencies: ["MisstypeCore"],
                path: "tests/MisstypeCoreTests"),
]
var dependencies: [Package.Dependency] = []
#if os(macOS)
// Sparkle is macOS-only and declared here so Linux never resolves it.
dependencies += [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
]
products += [
    .executable(name: "MisstypeIME", targets: ["MisstypeIME"]),
    .executable(name: "MisstypeSourceTool", targets: ["MisstypeSourceTool"]),
    .executable(name: "MisstypeInstaller", targets: ["MisstypeInstaller"]),
]
targets += [
    .executableTarget(
        name: "MisstypeIME",
        dependencies: ["MisstypeCore", .product(name: "Sparkle", package: "Sparkle")],
        // The packaged bundle carries Sparkle.framework in Contents/Frameworks.
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .executableTarget(name: "MisstypeSourceTool"),
    // Double-clickable installer shipped in the DMG (see docs/release.md).
    .executableTarget(name: "MisstypeInstaller"),
]
#endif

let package = Package(
    name: "MisstypeIME",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
