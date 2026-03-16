// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bleclip",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "bleclip",
            path: "Sources/bleclip",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
