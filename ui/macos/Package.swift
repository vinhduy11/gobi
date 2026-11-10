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
        // The terminal emulator view for the Terminal panel (MIT licence), vendored and patched: see Vendor/SwiftTerm/VENDORED.md. Only the app shell imports it.
        .package(path: "Vendor/SwiftTerm"),
        // Updates (MIT licence): the standard updater, EdDSA-verified. Only the app shell imports it; make-app.sh embeds and signs the framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Layer 1: logic with no imports at all (no Foundation, no AppKit). Same on every platform's port.
        .target(name: "GobiModel"),
        // Layer 2: talking to gobid (sockets, handshake, LSP and control clients). Foundation and Darwin, no AppKit.
        .target(name: "GobiClient", dependencies: ["GobiModel"]),
        // Layer 3: AppKit editor view built on the two layers below.
        .target(name: "GobiEditor", dependencies: ["GobiModel", "GobiClient"]),
        // Layer 4: the application shell.
        .executableTarget(name: "GobiApp", dependencies: ["GobiModel", "GobiClient", "GobiEditor", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "gobi-probe", dependencies: ["GobiModel", "GobiClient"]),
        .executableTarget(name: "gobi-bench", dependencies: ["GobiModel", "GobiClient", "GobiEditor"]),
        .executableTarget(name: "gobi-check", dependencies: ["GobiModel", "GobiClient", "GobiEditor"]),
        .testTarget(name: "GobiModelTests", dependencies: ["GobiModel"]),
        .testTarget(name: "GobiClientTests", dependencies: ["GobiModel", "GobiClient"]),
        // The patches to the vendored SwiftTerm (Vendor/SwiftTerm/VENDORED.md), each with its test.
        .testTarget(name: "TerminalForkTests", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
    ],
    swiftLanguageModes: [.v5]
)
