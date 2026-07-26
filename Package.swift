// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YouTubeTranscript",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "YouTubeTranscriptKit", targets: ["YouTubeTranscriptKit"]),
        .executable(name: "ytt", targets: ["YouTubeTranscript"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "YouTubeTranscriptKit",
            dependencies: []
        ),
        .executableTarget(
            name: "YouTubeTranscript",
            dependencies: [
                "YouTubeTranscriptKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "YouTubeTranscriptKitTests",
            dependencies: ["YouTubeTranscriptKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
