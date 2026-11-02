// swift-tools-version: 6.0
//
// MinuitCore : toute la logique métier de l'application, sans dépendance à UIKit,
// AVFoundation ni SwiftUI. Ce paquet compile et se teste sous Linux (Docker sur le
// NAS, ou runner Linux GitHub), ce qui évite de consommer des minutes macOS pour
// valider le parsing Xtream / XMLTV, les fuseaux horaires, le zapping, le catch-up
// et la persistance.

import PackageDescription

let package = Package(
    name: "MinuitCore",
    platforms: [
        .tvOS(.v18),
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "MinuitCore", targets: ["MinuitCore"]),
    ],
    targets: [
        .target(
            name: "MinuitCore",
            path: "Sources/MinuitCore"
        ),
        .testTarget(
            name: "MinuitCoreTests",
            dependencies: ["MinuitCore"],
            path: "Tests/MinuitCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
