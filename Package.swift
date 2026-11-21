// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ForgejoNotify",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ForgejoNotify", targets: ["ForgejoNotify"]),
    ],
    targets: [
        .executableTarget(
            name: "ForgejoNotify",
            path: "Sources/ForgejoNotify"
        ),
    ]
)
