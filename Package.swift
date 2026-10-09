// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Lilt", platforms: [.macOS(.v26)], products: [
    .executable(name: "Lilt", targets: ["Lilt"]), .library(name: "LiltCore", targets: ["LiltCore"])
], targets: [.target(name: "LiltCore"), .executableTarget(name: "Lilt", dependencies: ["LiltCore"]), .executableTarget(name: "LiltChecks", dependencies: ["LiltCore"], path: "Tests/LiltCoreTests")])
