// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Clementine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clementine",
            path: "Sources/Clementine",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        )
    ]
)
