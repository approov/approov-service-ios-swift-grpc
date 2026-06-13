// swift-tools-version:5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription
// Release tag
let releaseTAG = "3.5.4"
// SDK package version (used for both iOS and watchOS)
let sdkVersion: Version = "3.5.3"


let package = Package(
    name: "ApproovGRPCSession",
    platforms: [
        .iOS(.v11),
        .watchOS(.v9)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "ApproovGRPCSession",
            targets: ["ApproovGRPCSession"]
        ),
        .library(name: "ApproovGRPCSessionDynamic", type: .dynamic, targets: ["ApproovGRPCSession"])
    ],
    dependencies: [
        // Package's external dependencies and from where they can be fetched:
        .package(url: "https://github.com/approov/approov-ios-sdk.git", exact: sdkVersion),
        .package(url: "https://github.com/grpc/grpc-swift.git", .upToNextMajor(from: "1.0.0")),
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.0.0"))
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "ApproovGRPCSession",
            dependencies: [
                .product(name: "Approov", package: "approov-ios-sdk"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/ApproovGRPC"
        )
    ]
)
