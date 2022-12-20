// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let approovSDKVersion = "3.1.0"
let bitcode = "" // "" or "-bitcode"
let approovSDKChecksum = "9514279f8db428f46ecd9c855a89e25f580069e703e2e2940d3aa7a752040232"

let package = Package(
    name: "ApproovGRPC",
    platforms: [.iOS(.v10)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "ApproovGRPC",
            targets: ["ApproovGRPC", "Approov"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", .upToNextMajor(from: "1.5.0"))
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "ApproovGRPC",
            dependencies: [.product(name: "GRPC", package: "grpc-swift")]
        ),
        .binaryTarget(
            name: "Approov",
            url: "https://github.com/approov/approov-ios-sdk" + bitcode + "/releases/download/" + approovSDKVersion +
                "/Approov.xcframework.zip",
            checksum : approovSDKChecksum
        )
    ]
)
