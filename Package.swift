// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fictura",
    platforms: [
        .iOS(.v15),
        // macOS only so `swift test` can run the platform-independent core on a Mac.
        .macOS(.v12),
    ],
    products: [
        .library(name: "FicturaSDK", targets: ["FicturaSDK"]),
    ],
    targets: [
        .target(
            name: "FicturaSDK",
            resources: [.copy("PrivacyInfo.xcprivacy"), .copy("Paywall/binder.js")]
        ),
        .testTarget(
            name: "FicturaSDKTests",
            dependencies: ["FicturaSDK"],
            resources: [.copy("Vectors")]
        ),
    ]
)
