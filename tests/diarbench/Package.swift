// swift-tools-version: 6.0
// Regression bench for VoiceIdentity (the "100 speakers" bug). See README.md.
import PackageDescription
let package = Package(
  name: "diarbench",
  platforms: [.macOS(.v14)],
  dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.14.5")],
  targets: [.executableTarget(name: "diarbench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                              swiftSettings: [.swiftLanguageMode(.v5)])]
)
