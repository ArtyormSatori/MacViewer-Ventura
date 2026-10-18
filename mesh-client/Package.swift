// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeshClient",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MeshClient", targets: ["MeshClient"]),
        .executable(name: "mesh-smoke", targets: ["mesh-smoke"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "MeshClient",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .executableTarget(
            name: "mesh-smoke",
            dependencies: ["MeshClient"]
        ),
        .testTarget(
            name: "MeshClientTests",
            dependencies: ["MeshClient"]
        ),
    ]
)
