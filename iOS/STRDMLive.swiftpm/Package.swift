// swift-tools-version: 5.9

// STRDM Live — native iPhone & iPad control app for STRDM Stage.
// Open this folder in Xcode (or Swift Playgrounds on iPad) and press Run.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "STRDM Live Control",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "STRDM Live Control",
            targets: ["AppModule"],
            bundleIdentifier: "io.strdm.live.control",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.pink),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .localNetwork(purposeString: "STRDM Live finds and controls STRDM Stage on your Mac over the venue Wi-Fi.",
                              bonjourServiceTypes: ["_strdmlive._tcp"]),
                .camera(purposeString: "Scan the pairing QR code shown on the Mac.")
            ],
            appCategory: .music
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
