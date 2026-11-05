// swift-tools-version:6.0
import PackageDescription

// ponytail: Swift 5 language mode. Strict concurrency checking is deferred until the editor architecture
// is decided by this spike; revisit before the UI slice proper.
let package = Package(
    name: "GobiUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GobiClient", targets: ["GobiClient"]),
        .executable(name: "GobiApp", targets: ["GobiApp"]),
    ],
    targets: [
        .target(name: "GobiClient"),
        .target(name: "GobiEditor", dependencies: ["GobiClient"]),
        .executableTarget(name: "GobiApp", dependencies: ["GobiClient", "GobiEditor"]),
        .executableTarget(name: "gobi-probe", dependencies: ["GobiClient"]),
        .executableTarget(name: "gobi-bench", dependencies: ["GobiClient", "GobiEditor"]),
        .executableTarget(name: "gobi-check", dependencies: ["GobiClient", "GobiEditor"]),
        .testTarget(name: "GobiClientTests", dependencies: ["GobiClient"]),
    ],
    swiftLanguageModes: [.v5]
)
