// swift-tools-version:6.0
import Foundation
import PackageDescription

// Shipping builds omit hermetic suites and frozen-oracle CLI adapters. Developer
// checks use LEYLINE_BUILD_TESTS=1 and an isolated Swift scratch path.
let buildTests = ProcessInfo.processInfo.environment["LEYLINE_BUILD_TESTS"] == "1"
let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/leylined")
let testAdapters = ["ModelFn.swift", "ModelStore.swift", "ModelTargets.swift", "NavExplain.swift", "ProjectionMain.swift"]
let exclusions = buildTests ? [] : (try! FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path))
    .filter { $0.hasPrefix("SelfTest") || testAdapters.contains($0) }
let profile: [SwiftSetting] = buildTests ? [.define("LEYLINE_BUILD_TESTS")] : []

let package = Package(
    name: "Leyline",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CResidentAtomics", publicHeadersPath: "include"),
        .target(name: "LeylineModel", exclude: buildTests ? [] : ["Transitions/Perf.swift", "ResponsivenessEvidence.swift"], swiftSettings: profile),
        .executableTarget(name: "leylined", dependencies: ["LeylineModel", "CResidentAtomics"],
            exclude: exclusions, swiftSettings: profile),
    ]
)
