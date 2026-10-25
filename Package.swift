// swift-tools-version: 6.2
import PackageDescription
var products: [Product] = [
    .executable(name: "lilt", targets: ["LiltCLI"]),
    .library(name: "LiltCore", targets: ["LiltCore"]),
    .library(name: "LiltBackend", targets: ["LiltBackend"])
]
// LiltCore stays plain Foundation. Only the passphrase-encrypted account archive needs scrypt and AES-GCM on both
// macOS and Linux, so that one file lives in LiltTransfer with Apple's swift-crypto, pinned to one release.
var targets: [Target] = [
    .target(name: "LiltCore"),
    .target(name: "LiltTransfer", dependencies: [
        "LiltCore",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "CryptoExtras", package: "swift-crypto")
    ]),
    .target(name: "LiltBackend", dependencies: ["LiltCore", "LiltTransfer"]),
    .executableTarget(name: "LiltCLI", dependencies: ["LiltBackend", "LiltTransfer"], path: "Sources/LiltCLI"),
    .executableTarget(name: "LiltChecks", dependencies: ["LiltCore", "LiltTransfer"], path: "Tests/LiltCoreTests"),
    .executableTarget(name: "LiltBackendChecks", dependencies: ["LiltBackend", "LiltTransfer"], path: "Tests/LiltBackendTests")
]
#if os(macOS)
// The app's product is not called "Lilt": on a case-insensitive disk it would share `.build/<config>/lilt` with the
// CLI, and a full build would leave one binary in place of the other. The bundle still runs it as `Lilt`.
products.append(.executable(name: "LiltApp", targets: ["Lilt"]))
targets.append(.executableTarget(name: "Lilt", dependencies: ["LiltCore", "LiltTransfer"], path: "Sources/Lilt"))
#endif
let package = Package(
    name: "Lilt",
    platforms: [.macOS(.v26)],
    products: products,
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")],
    targets: targets
)
