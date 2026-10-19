// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeshClient",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MeshClient", targets: ["MeshClient"]),
        .library(name: "MeshWebRTC", targets: ["MeshWebRTC"]),
        .executable(name: "mesh-smoke", targets: ["mesh-smoke"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // stasel/WebRTC (mode2-phase3/M1_WEBRTC_DECISION.md): consumed
        // by the MeshWebRTC library target on macOS and by the
        // MeshWebRTCSpikeTests target. The pure MeshClient core never
        // depends on it.
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "155.0.0"),
    ],
    targets: [
        .target(
            name: "MeshClient",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "MeshWebRTC",
            dependencies: [
                "MeshClient",
                .product(name: "WebRTC", package: "WebRTC",
                         condition: .when(platforms: [.macOS])),
            ]
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
        .testTarget(
            name: "MeshWebRTCTests",
            dependencies: ["MeshWebRTC", "MeshClient"]
        ),
    ]
)
