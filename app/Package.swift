// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidecarSwitch",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "SidecarSwitch", targets: ["SidecarSwitch"])
    ],
    targets: [
        .target(
            name: "SidecarSwitchCore",
            path: "Sources/SidecarSwitchCore"
        ),
        .executableTarget(
            name: "SidecarSwitch",
            dependencies: ["SidecarSwitchCore"],
            path: "Sources/SidecarSwitch"
        ),
        .testTarget(
            name: "SidecarSwitchTests",
            dependencies: ["SidecarSwitchCore", "SidecarSwitch"],
            path: "Tests/SidecarSwitchTests"
        )
    ]
)
