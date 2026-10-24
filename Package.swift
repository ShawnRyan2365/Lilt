// swift-tools-version: 6.2
import PackageDescription
var products: [Product] = [
    .executable(name: "lilt", targets: ["LiltCLI"]),
    .library(name: "LiltCore", targets: ["LiltCore"]),
    .library(name: "LiltBackend", targets: ["LiltBackend"])
]
var targets: [Target] = [
    .target(name: "LiltCore"),
    .target(name: "LiltBackend", dependencies: ["LiltCore"]),
    .executableTarget(name: "LiltCLI", dependencies: ["LiltBackend"], path: "Sources/LiltCLI"),
    .executableTarget(name: "LiltChecks", dependencies: ["LiltCore"], path: "Tests/LiltCoreTests"),
    .executableTarget(name: "LiltBackendChecks", dependencies: ["LiltBackend"], path: "Tests/LiltBackendTests")
]
#if os(macOS)
products.append(.executable(name: "Lilt", targets: ["Lilt"]))
targets.append(.executableTarget(name: "Lilt", dependencies: ["LiltCore"], path: "Sources/Lilt"))
#endif
let package = Package(name: "Lilt", platforms: [.macOS(.v26)], products: products, targets: targets)
