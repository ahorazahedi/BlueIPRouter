// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BlueIPRouter",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BlueIPRouter", targets: ["BlueIPRouter"]),
        .executable(name: "blueiprouter-helper", targets: ["blueiprouter-helper"]),
    ],
    targets: [
        // Shared models, validation, route parsing and planning (used by the app and the root helper).
        .target(name: "BlueIPRouterCore"),
        // SwiftUI desktop app.
        .executableTarget(
            name: "BlueIPRouter",
            dependencies: ["BlueIPRouterCore"],
            resources: [.process("Resources")]
        ),
        // Small root helper that applies routes; installed to /Library/PrivilegedHelperTools.
        .executableTarget(name: "blueiprouter-helper", dependencies: ["BlueIPRouterCore"]),
    ]
)
