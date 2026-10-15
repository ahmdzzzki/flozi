// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flozi",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Flozi", targets: ["Flozi"])],
    targets: [
        .target(name: "FloziCore"),
        .executableTarget(name: "Flozi", dependencies: ["FloziCore"]),
        .testTarget(name: "FloziCoreTests", dependencies: ["FloziCore"])
    ]
)
