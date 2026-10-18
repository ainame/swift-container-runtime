// swift-tools-version: 6.4
import PackageDescription

let checkedSwiftSettings: [SwiftSetting] = [
    .strictMemorySafety(),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "swift-container-runtime",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ContainerRuntime", targets: ["ContainerRuntime"]),
        .executable(name: "swift-container-runtime", targets: ["RuntimeCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-system", from: "1.8.1"),
    ],
    targets: [
        .systemLibrary(name: "LinuxAPI"),
        .target(
            name: "ContainerRuntime",
            dependencies: [
                .target(name: "LinuxAPI", condition: .when(platforms: [.linux])),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: checkedSwiftSettings
        ),
        .executableTarget(
            name: "RuntimeCLI",
            dependencies: [
                "ContainerRuntime",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: checkedSwiftSettings
        ),
        .testTarget(
            name: "ContainerRuntimeTests",
            dependencies: [
                "ContainerRuntime",
                .target(name: "LinuxAPI", condition: .when(platforms: [.linux])),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: checkedSwiftSettings
        ),
        .testTarget(
            name: "RuntimeCLITests",
            dependencies: [
                "RuntimeCLI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: checkedSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
