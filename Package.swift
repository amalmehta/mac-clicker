// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacClicker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacClicker",
            path: "Sources/MacClicker",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
