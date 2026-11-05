// swift-tools-version:6.0
import PackageDescription

// ponytail: Swift 5 language mode. Strict concurrency checking is deferred until the editor architecture
// is decided by this spike; revisit before the UI slice proper.
let package = Package(
    name: "GobiUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GobiModel", targets: ["GobiModel"]),
        .library(name: "GobiClient", targets: ["GobiClient"]),
        .executable(name: "GobiApp", targets: ["GobiApp"]),
    ],
    dependencies: [
        // The terminal emulator view for the Terminal panel (MIT licence). Only the app shell imports it.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.5.1"),
    ],
    targets: [
        // Layer 1: logic with no imports at all (no Foundation, no AppKit). Same on every platform's port.
        .target(name: "GobiModel"),
        // Layer 2: talking to gobid (sockets, handshake, LSP and control clients). Foundation and Darwin, no AppKit.
        .target(name: "GobiClient", dependencies: ["GobiModel"]),
        // Layer 3: AppKit editor view built on the two layers below.
        .target(name: "GobiEditor", dependencies: ["GobiModel", "GobiClient"]),
        // Layer 4: the application shell.
        .executableTarget(name: "GobiApp", dependencies: ["GobiModel", "GobiClient", "GobiEditor", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "gobi-probe", dependencies: ["GobiModel", "GobiClient"]),
        .executableTarget(name: "gobi-bench", dependencies: ["GobiModel", "GobiClient", "GobiEditor"]),
        .executableTarget(name: "gobi-check", dependencies: ["GobiModel", "GobiClient", "GobiEditor"]),
        .testTarget(name: "GobiModelTests", dependencies: ["GobiModel"]),
        .testTarget(name: "GobiClientTests", dependencies: ["GobiModel", "GobiClient"]),
    ],
    swiftLanguageModes: [.v5]
)
