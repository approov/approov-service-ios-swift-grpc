// swift-tools-version:5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription
import Foundation

// Release tag - defaults to "dev" for local development and CI testing.
// Placed here as a placeholder to be dynamically replaced during the tagging pipeline.
let releaseTAG = "dev"

// SDK package version (used for both iOS and watchOS in production)
let sdkVersion: Version = "3.5.3"

// NOTE: The useMiniSDK flag and miniSDKPath are used for local and CI automated testing only.
// They are not included or used in production releases, which depend exclusively on the real approov-ios-sdk.
// This is a testing requirement and has no production dependency.
let useMiniSDK = ProcessInfo.processInfo.environment["APPROOV_USE_MINI_SDK"] == "1"
let miniSDKPath = ProcessInfo.processInfo.environment["APPROOV_MINI_SDK_PATH"] ?? ""

let approovPackageName = useMiniSDK ? "mini-sdk-ios" : "approov-ios-sdk"
let packagePlatforms: [SupportedPlatform] = useMiniSDK
    ? [
        .iOS(.v11),
        .watchOS(.v9),
        .macOS(.v13)
    ]
    : [
        .iOS(.v11),
        .watchOS(.v9)
    ]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/grpc/grpc-swift.git", .upToNextMajor(from: "1.0.0")),
    .package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.0.0"))
]

if useMiniSDK {
    // Local Mini-SDK dependency for testing purposes only.
    // This is a testing requirement and has no production dependency.
    packageDependencies.append(.package(name: "mini-sdk-ios", path: miniSDKPath))
} else {
    // Production release dependency on the official Approov iOS SDK.
    packageDependencies.append(.package(url: "https://github.com/approov/approov-ios-sdk.git", exact: sdkVersion))
}

var packageTargets: [Target] = [
    .target(
        name: "ApproovGRPCSession",
        dependencies: [
            .product(name: "Approov", package: approovPackageName),
            .product(name: "GRPC", package: "grpc-swift"),
            .product(name: "Logging", package: "swift-log")
        ],
        path: "Sources/ApproovGRPC"
    )
]

if useMiniSDK {
    // Test target for verifying the package locally/CI using the mock Mini-SDK.
    // This is a testing requirement and has no production dependency.
    packageTargets.append(
        .testTarget(
            name: "ApproovGRPCMiniSDKTests",
            dependencies: [
                "ApproovGRPCSession",
                .product(name: "Approov", package: "mini-sdk-ios"),
                .product(name: "MiniSDKTestSupport", package: "mini-sdk-ios")
            ],
            path: "Tests/ApproovGRPCMiniSDKTests"
        )
    )
}

let package = Package(
    name: "ApproovGRPCSession",
    platforms: packagePlatforms,
    products: [
        .library(
            name: "ApproovGRPCSession",
            targets: ["ApproovGRPCSession"]
        ),
        .library(name: "ApproovGRPCSessionDynamic", type: .dynamic, targets: ["ApproovGRPCSession"])
    ],
    dependencies: packageDependencies,
    targets: packageTargets
)
