// swift-tools-version: 6.0
import PackageDescription

// Reading Markdown documents, the same on the Mac and on the phone.
let package = Package(
    name: "Document",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "NoodleDocument", targets: ["NoodleDocument"])
    ],
    targets: [
        .target(name: "NoodleDocument"),
        .testTarget(name: "NoodleDocumentTests", dependencies: ["NoodleDocument"])
    ]
)
