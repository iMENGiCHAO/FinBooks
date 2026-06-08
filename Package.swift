// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FinBooks",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FinBooks", targets: ["FinBooks"])
    ],
    targets: [
        .executableTarget(
            name: "FinBooks",
            path: "Sources/FinBooks"
        )
    ]
)
