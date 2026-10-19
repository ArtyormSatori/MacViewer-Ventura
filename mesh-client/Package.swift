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
        // M1 spike only (mode2-phase3/M1_WEBRTC_DECISION.md): the WebRTC
        // binary is consumed exclusively by the MeshWebRTCSpikeTests target
        // on macOS. No library/executable product depends on it yet.
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "155.0.0"),
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
        .testTarget(
            name: "MeshWebRTCSpikeTests",
            dependencies: [
                "MeshClient",
                .product(name: "WebRTC", package: "WebRTC",
                         condition: .when(platforms: [.macOS])),
            ]
        ),
    ]
)
