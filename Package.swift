// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "STRDMStage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "STRDMStage", targets: ["STRDMStage"])
    ],
    targets: [
        .executableTarget(
            name: "STRDMStage",
            path: "Sources/STRDMStage",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreAudioKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore")
            ]
        )
    ]
)
