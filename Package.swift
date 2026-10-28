// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Gifmator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Gifmator", targets: ["Gifmator"])
    ],
    targets: [
        .executableTarget(
            name: "Gifmator",
            path: "Sources/Gifmator"
        )
    ]
)
