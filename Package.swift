// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacadeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacadeKit", targets: ["MacadeKit"]),
        .executable(name: "mapc", targets: ["mapc"]),
    ],
    targets: [
        .target(name: "MacadeKit"),
        // `mapc`: runs Windows programs the way the MaPC app does, so changes can be tried without the app.
        .target(name: "MapcCommand", dependencies: ["MacadeKit"]),
        .executableTarget(name: "mapc", dependencies: ["MapcCommand"]),
        .testTarget(
            name: "MacadeKitTests",
            dependencies: ["MacadeKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MapcCommandTests", dependencies: ["MapcCommand"]),
    ]
)
