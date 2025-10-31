// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CRDTSQLite",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(
            name: "CRDTSQLite",
            targets: ["CRDTSQLite"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CRDTSQLite",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CRDTSQLiteTests",
            dependencies: ["CRDTSQLite"]
        ),
    ]
)
