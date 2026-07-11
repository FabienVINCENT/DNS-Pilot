// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DNSPilot",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DNSPilot",
            path: "Sources/DNSPilot"
        )
    ]
)
