// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MetaShield",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "MetaShieldCore", targets: ["MetaShieldCore"]),
    .executable(name: "MetaShield", targets: ["MetaShieldApp"]),
    .executable(name: "MetaShieldShare", targets: ["MetaShieldShare"]),
    .executable(name: "metashield-cli", targets: ["MetaShieldCLI"]),
    .executable(name: "metashield-self-test", targets: ["MetaShieldSelfTest"]),
    .executable(name: "MetaShieldDecodeService", targets: ["MetaShieldDecodeService"]),
  ],
  targets: [
    .target(
      name: "MetaShieldCore",
      linkerSettings: [
        .linkedFramework("Accelerate"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CryptoKit"),
        .linkedFramework("ImageIO"),
        .linkedLibrary("z"),
      ]
    ),
    .executableTarget(
      name: "MetaShieldApp",
      dependencies: ["MetaShieldCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Photos"),
        .linkedFramework("UniformTypeIdentifiers"),
      ]
    ),
    .executableTarget(
      name: "MetaShieldCLI",
      dependencies: ["MetaShieldCore"]
    ),
    .executableTarget(
      name: "MetaShieldShare",
      dependencies: ["MetaShieldCore"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Photos"),
        .linkedFramework("UniformTypeIdentifiers"),
      ]
    ),
    .executableTarget(
      name: "MetaShieldDecodeService",
      dependencies: ["MetaShieldCore"],
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
      ]
    ),
    .executableTarget(
      name: "MetaShieldSelfTest",
      dependencies: ["MetaShieldCore"],
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("ImageIO"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
