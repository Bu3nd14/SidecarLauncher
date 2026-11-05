// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidecarSwitch",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "SidecarSwitch", targets: ["SidecarSwitch"]),
        .library(name: "SidecarIcon", targets: ["SidecarIcon"]),
        .executable(name: "IconGen", targets: ["IconGen"])
    ],
    targets: [
        .target(
            name: "SidecarSwitchCore",
            path: "Sources/SidecarSwitchCore"
        ),
        .target(
            name: "SidecarIcon",
            dependencies: ["SidecarSwitchCore"],
            path: "Sources/SidecarIcon"
        ),
        .executableTarget(
            name: "IconGen",
            dependencies: ["SidecarIcon", "SidecarSwitchCore"],
            path: "Sources/IconGen"
        ),
        .executableTarget(
            name: "SidecarSwitch",
            dependencies: ["SidecarSwitchCore", "SidecarIcon"],
            path: "Sources/SidecarSwitch"
        ),
        .testTarget(
            name: "SidecarSwitchTests",
            dependencies: ["SidecarSwitchCore", "SidecarIcon", "SidecarSwitch"],
            path: "Tests/SidecarSwitchTests"
        )
    ]
)
