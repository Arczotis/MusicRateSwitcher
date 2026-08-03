// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MusicRateSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RateSwitcherCore", targets: ["RateSwitcherCore"]),
        .executable(name: "MusicRateSwitcher", targets: ["MusicRateSwitcher"]),
        .executable(name: "RateSwitcherSelfTest", targets: ["RateSwitcherSelfTest"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite"
        ),
        .target(
            name: "RateSwitcherCore",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "MusicRateSwitcher",
            dependencies: ["RateSwitcherCore"],
            path: "Sources/MusicRateSwitcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "RateSwitcherSelfTest",
            dependencies: ["RateSwitcherCore"]
        )
    ]
)
