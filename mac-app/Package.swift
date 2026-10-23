// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProxmoxManager",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ProxmoxKit",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ProxmoxManager",
            dependencies: ["ProxmoxKit"]
        ),
        .testTarget(
            name: "ProxmoxKitTests",
            dependencies: ["ProxmoxKit"]
        )
    ]
)
