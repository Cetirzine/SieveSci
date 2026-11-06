// swift-tools-version:6.0
import PackageDescription

// SieveSciCore is Foundation + cross-platform libraries only, so it builds and tests on Linux as
// well as macOS. The SwiftUI app target (and its UI-only dependencies) is declared on macOS only.
var dependencies: [Package.Dependency] = [
    // Official Model Context Protocol SDK: MCP client (stdio + streamable HTTP) and the `Value` JSON type.
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    // SHA-256 for the tamper-evident audit chain and data fingerprints (CryptoKit API on Linux too).
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    // YAML front matter in SKILL.md / command files and the settings file.
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    // Server-sent events parsing for streaming provider responses.
    .package(url: "https://github.com/mattt/EventSource.git", from: "1.1.0"),
    // FileDescriptor for wiring subprocess pipes into the MCP stdio transport on Linux.
    .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
    // Logger for the Windows stdio MCP transport (already used by the MCP SDK).
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
]

var products: [Product] = [
    .library(name: "SieveSciCore", targets: ["SieveSciCore"]),
    .executable(name: "sievesci", targets: ["sievesci-cli"]),
]

let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

var targets: [Target] = [
    .target(
        name: "SieveSciCore",
        dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Yams", package: "Yams"),
            .product(name: "EventSource", package: "EventSource"),
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "Logging", package: "swift-log"),
        ],
        path: "Sources/SieveSciCore",
        resources: [.copy("Resources"), .process("Localization")],
        swiftSettings: swift5Mode,
        // Windows: Recycle Bin (Platform.moveToTrash) and Credential Manager (PlatformSecretStore).
        linkerSettings: [.linkedLibrary("Shell32", .when(platforms: [.windows])), .linkedLibrary("Advapi32", .when(platforms: [.windows]))]
    ),
    .executableTarget(name: "sievesci-cli", dependencies: ["SieveSciCore"], path: "Sources/sievesci-cli", swiftSettings: swift5Mode),
    .testTarget(name: "SieveSciCoreTests", dependencies: ["SieveSciCore"], path: "Tests/SieveSciCoreTests", swiftSettings: swift5Mode),
]

#if os(macOS)
dependencies += [
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
    .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    // LaTeX in the transcript, rendered natively (MIT).
    .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.3"),
]
products.append(.executable(name: "SieveSci", targets: ["SieveSciApp"]))
targets.append(.executableTarget(
    name: "SieveSciApp",
    dependencies: [
        "SieveSciCore",
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        .product(name: "KeychainAccess", package: "KeychainAccess"),
        .product(name: "SwiftMath", package: "SwiftMath"),
    ],
    path: "Sources/SieveSciApp",
    swiftSettings: swift5Mode
))
#endif

let package = Package(
    name: "SieveSci",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
