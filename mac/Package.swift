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
        // Déclarations des classes privées de CoreGraphics pour l'écran virtuel.
        .target(
            name: "CGVirtualDisplayBridge",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // Toute la logique, testable, sans UI.
        .target(name: "SidebusCore", dependencies: ["CGVirtualDisplayBridge"]),
        // Application menu bar.
        .executableTarget(
            name: "SidebusApp",
            dependencies: ["SidebusCore"],
            // Les gabarits PDF de la barre de menus, lus via Bundle.module.
            resources: [.process("Resources")]
        ),
        .testTarget(name: "SidebusCoreTests", dependencies: ["SidebusCore"]),
    ]
)
