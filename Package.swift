// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-container-runtime",
    products: [
        .library(name: "ContainerRuntime", targets: ["ContainerRuntime"]),
        .executable(name: "swift-container-runtime", targets: ["RuntimeCLI"]),
    ],
    targets: [
        .target(name: "CRuntime"),
        .target(name: "ContainerRuntime", dependencies: ["CRuntime"]),
        .executableTarget(name: "RuntimeCLI", dependencies: ["ContainerRuntime"]),
        .testTarget(name: "ContainerRuntimeTests", dependencies: ["ContainerRuntime"]),
    ],
    swiftLanguageModes: [.v6]
)
