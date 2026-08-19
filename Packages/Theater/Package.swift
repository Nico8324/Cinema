// swift-tools-version:6.0

// The Theater immersive environment: a black auditorium whose only visible
// surfaces are the ceiling and floor caught in the spill of light from the screen.

import PackageDescription

let package = Package(
    name: "Theater",
    platforms: [
        .visionOS(.v2),
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "Theater",
            targets: ["Theater"])
    ],
    targets: [
        .target(
            name: "Theater")
    ]
)
