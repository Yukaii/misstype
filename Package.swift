// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The core is Zig (core-zig/, docs/zig-port.md). SwiftPM builds only the macOS
// side: the InputMethodKit adapter, its Settings UI, the installer, the Carbon
// source tool, and the thin Swift bridge to the C ABI (CMisstype/include/misstype.h).
// `./script/zig/build_macos.sh` produces the universal libMisstypeCAPI.dylib
// that the adapter and the bridge link by absolute path (a library search flag
// alone can pick SwiftPM's same-named reference library first).
var products: [Product] = []
var targets: [Target] = []
var dependencies: [Package.Dependency] = []
#if os(macOS)
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let zigLibraryDir = "\(packageRoot)/dist/zig/macos-universal"
// Sparkle is macOS-only and declared here so other platforms never resolve it.
dependencies += [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
]
products += [
    .executable(name: "MisstypeIME", targets: ["MisstypeIME"]),
    .executable(name: "MisstypeSourceTool", targets: ["MisstypeSourceTool"]),
    .executable(name: "MisstypeInstaller", targets: ["MisstypeInstaller"]),
    .executable(name: "MisstypeZigSmoke", targets: ["MisstypeZigSmoke"]),
]
targets += [
    .target(name: "CMisstype"),
    // UI-side types of the IME (key events, view model, preferences model,
    // key-binding editor, candidate row windows); the Zig core owns every
    // editing rule.
    .target(name: "MisstypeMacKit"),
    .testTarget(name: "MisstypeMacKitTests", dependencies: ["MisstypeMacKit"],
                path: "tests/MisstypeMacKitTests"),
    .executableTarget(
        name: "MisstypeIME",
        dependencies: ["MisstypeMacKit", "MisstypeZigBridge", .product(name: "Sparkle", package: "Sparkle")],
        // The packaged bundle carries Sparkle.framework in Contents/Frameworks.
        linkerSettings: [.unsafeFlags(["\(zigLibraryDir)/libMisstypeCAPI.dylib",
                                       "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .executableTarget(name: "MisstypeSourceTool"),
    // Double-clickable installer shipped in the DMG (see docs/release.md).
    .executableTarget(name: "MisstypeInstaller"),
    .target(
        name: "MisstypeZigBridge",
        dependencies: ["CMisstype"],
        linkerSettings: [
            .unsafeFlags(["\(zigLibraryDir)/libMisstypeCAPI.dylib",
                          "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../zig"])
        ]),
    .executableTarget(name: "MisstypeZigSmoke", dependencies: ["MisstypeZigBridge"]),
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
