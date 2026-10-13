// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Camdeck",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Camdeck", targets: ["Camdeck"]),
        .executable(name: "uvcctl", targets: ["uvcctl"]),
        .library(name: "UVCKit", targets: ["UVCKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0"),
    ],
    targets: [
        .target(name: "UVCKit", resources: [.copy("Resources/Profiles")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Camdeck", dependencies: ["UVCKit", .product(name: "Sparkle", package: "Sparkle")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "uvcctl", dependencies: ["UVCKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "UVCKitTests",
            dependencies: ["UVCKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
