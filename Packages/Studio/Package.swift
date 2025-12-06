// swift-tools-version:6.0
/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Extensions to the Studio asset.
*/

// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Studio",
    platforms: [
        .visionOS(.v2),
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "Studio",
            targets: ["Studio"])
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "Studio",
            dependencies: [])
    ]
)
