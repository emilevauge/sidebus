// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sidebus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SidebusApp", targets: ["SidebusApp"]),
        .library(name: "SidebusCore", targets: ["SidebusCore"]),
    ],
    targets: [
        // Declarations of the private CoreGraphics classes for the virtual display.
        .target(
            name: "CGVirtualDisplayBridge",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // All the logic, testable, with no UI.
        .target(name: "SidebusCore", dependencies: ["CGVirtualDisplayBridge"]),
        // Menu bar application.
        .executableTarget(
            name: "SidebusApp",
            dependencies: ["SidebusCore"],
            // The menu bar PDF templates, read through Bundle.module.
            resources: [.process("Resources")]
        ),
        .testTarget(name: "SidebusCoreTests", dependencies: ["SidebusCore"]),
    ]
)
