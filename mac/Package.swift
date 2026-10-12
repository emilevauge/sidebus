// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sidebus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SidebusApp", targets: ["SidebusApp"]),
        .library(name: "SidebusCore", targets: ["SidebusCore"]),
        .executable(name: "HandsFreeProbe", targets: ["HandsFreeProbe"]),
        .executable(name: "CallAudioBridge", targets: ["CallAudioBridge"]),
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
        // Throwaway probe: can the Mac be a Bluetooth hands-free unit for a phone?
        // The Info.plist is embedded in the binary so TCC can ask for Bluetooth access.
        .executableTarget(
            name: "HandsFreeProbe",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/HandsFreeProbe/Info.plist",
                ]),
            ]
        ),
        // Throwaway probe: plays a call's audio from the phone and sends the
        // microphone back, over the adb forward set up by android/callaudioprobe.
        .executableTarget(
            name: "CallAudioBridge",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CallAudioBridge/Info.plist",
                ]),
            ]
        ),
        .testTarget(name: "SidebusCoreTests", dependencies: ["SidebusCore"]),
    ]
)
