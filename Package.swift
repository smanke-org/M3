// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MouseMileage",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MouseMileage",
            path: "Sources/MouseMileage"
        ),
        .testTarget(
            name: "MouseMileageTests",
            dependencies: ["MouseMileage"],
            path: "Tests/MouseMileageTests"
        )
    ]
)
