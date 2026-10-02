// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacClicker",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure decision logic, kept free of AppKit so it can be tested directly.
        .target(name: "MacClickerKit", path: "Sources/MacClickerKit"),
        .executableTarget(
            name: "MacClicker",
            dependencies: ["MacClickerKit"],
            path: "Sources/MacClicker",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "MacClickerKitTests",
            dependencies: ["MacClickerKit"],
            path: "Tests/MacClickerKitTests"
        )
    ]
)
