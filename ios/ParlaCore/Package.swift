// swift-tools-version:5.9
// Platform-independent part of the iOS app: course model, lesson engine, grading, progress rules,
// JSON codec, HTTP client, offline store and the repository that keeps everything in sync.
// Mirrors the Kotlin module shared/ of the Android and desktop apps. Run the tests with `swift test`.
import PackageDescription

let package = Package(
    name: "ParlaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ParlaCore", targets: ["ParlaCore"]),
    ],
    targets: [
        .target(name: "ParlaCore"),
        // Test copies of the real course files (from Parla-Studio/parla-server, content/courses).
        .testTarget(name: "ParlaCoreTests", dependencies: ["ParlaCore"], resources: [.copy("courses")]),
    ]
)
