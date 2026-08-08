// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PatronArchiverKit",
    defaultLocalization: "en",
    platforms: [
        .macOS("15.6"),
        .iOS("18.6"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PatronArchiverKit",
            targets: ["PatronArchiverKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-structured-headers.git", from: "1.6.0"),
        // Only the `UserDefaults` Codable subscript (UserDefaultsKitCore) is used here; the SwiftUI
        // and Combine traits are the app target's concern, so they are disabled on this edge. In an
        // app build the trait union re-enables them (SE-0450), so this only keeps the Kit's own
        // standalone build Core-only.
        .package(url: "https://github.com/sinoru/swift-user-defaults-kit.git", exact: "0.0.1", traits: []),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PatronArchiverKit",
            dependencies: [
                .product(name: "RawStructuredFieldValues", package: "swift-http-structured-headers"),
                .product(name: "UserDefaultsKit", package: "swift-user-defaults-kit"),
            ],
            resources: [
                .copy("LazyContentLoader/LazyContentLoader.js"),
            ]
        ),
        .testTarget(
            name: "PatronArchiverKitTests",
            dependencies: ["PatronArchiverKit"]
        ),
    ]
)
