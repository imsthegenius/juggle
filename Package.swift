// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Juggle",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.2.5"),
    ],
    targets: [
        .executableTarget(
            name: "Juggle",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
            ],
            path: "Sources/Juggle"
        ),
        .testTarget(
            name: "JuggleTests",
            dependencies: ["Juggle"],
            path: "Tests/JuggleTests"
        ),
    ]
)
