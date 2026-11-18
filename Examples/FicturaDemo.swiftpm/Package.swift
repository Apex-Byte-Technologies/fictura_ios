// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "FicturaDemo",
    platforms: [.iOS("16.0")],
    products: [
        .iOSApplication(
            name: "FicturaDemo",
            targets: ["AppModule"],
            bundleIdentifier: "co.fictura.demo",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .sparkle),
            accentColor: .presetColor(.purple),
            supportedDeviceFamilies: [.phone],
            supportedInterfaceOrientations: [.portrait]
        ),
    ],
    dependencies: [.package(name: "Fictura", path: "../..")],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [.product(name: "FicturaSDK", package: "Fictura")],
            path: "."
        ),
    ]
)
