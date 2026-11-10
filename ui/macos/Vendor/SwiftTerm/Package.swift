// swift-tools-version:5.9
import PackageDescription

// SwiftTerm 1.5.1 (MIT), vendored and patched for Gobi. See VENDORED.md.
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(name: "SwiftTerm", path: "Sources/SwiftTerm")]
)
