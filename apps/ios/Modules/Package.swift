// swift-tools-version: 6.4
import PackageDescription

// Module graph (see apps/ios/AGENTS.md "Modules and ownership"). Dependency direction is top to bottom:
//
//   features (Auth, Library, Tags, Search, Reader, Settings, Share)  -> SrokaCore, SrokaDesign, SrokaTesting
//   engine   (Sync, Content, Session)                                -> SrokaNetwork, SrokaDatabase, SrokaCore
//   data     (Network, Database)                                     -> SrokaCore
//   shared   (Design -> Core; Testing -> Core)
//
// Features never import each other or any engine/data module; only the composition roots (app, share
// extension) do. An illegal import is a compile error because it is not listed here.
//
// Each stream edits only its own target's lines below.

let dependencies: Target.Dependency = .product(name: "Dependencies", package: "swift-dependencies")
let clocks: Target.Dependency = .product(name: "Clocks", package: "swift-clocks")

/// Feature modules see domain protocols (SrokaCore), design tokens and the fakes for previews.
let featureDependencies: [Target.Dependency] = ["SrokaCore", "SrokaDesign", "SrokaTesting", dependencies]

/// Every feature owns its strings (`bundle: #bundle` needs a resource bundle).
let featureResources: [Resource] = [.process("Localizable.xcstrings")]

/// Test targets get the module under test, the fakes, Dependencies and Clocks.
func testDependencies(_ module: Target.Dependency) -> [Target.Dependency] {
    [module, "SrokaTesting", dependencies, clocks]
}

let package = Package(
    name: "Modules",
    // Required before any target can carry a String Catalog.
    defaultLocalization: "en",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "SrokaCore", targets: ["SrokaCore"]),
        .library(name: "SrokaTesting", targets: ["SrokaTesting"]),
        .library(name: "SrokaDesign", targets: ["SrokaDesign"]),
        .library(name: "SrokaNetwork", targets: ["SrokaNetwork"]),
        .library(name: "SrokaDatabase", targets: ["SrokaDatabase"]),
        .library(name: "SrokaSync", targets: ["SrokaSync"]),
        .library(name: "SrokaContent", targets: ["SrokaContent"]),
        .library(name: "SrokaSession", targets: ["SrokaSession"]),
        .library(name: "AuthFeature", targets: ["AuthFeature"]),
        .library(name: "LibraryFeature", targets: ["LibraryFeature"]),
        .library(name: "TagsFeature", targets: ["TagsFeature"]),
        .library(name: "SearchFeature", targets: ["SearchFeature"]),
        .library(name: "ReaderFeature", targets: ["ReaderFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
        .library(name: "ShareFeature", targets: ["ShareFeature"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.1"),
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.1.1"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        // MARK: Shared layers (stream F; SrokaCore/Logic is stream A, SrokaDesign/Components is stream C)
        .target(name: "SrokaCore", dependencies: [dependencies]),
        .target(name: "SrokaTesting", dependencies: ["SrokaCore", dependencies]),
        .target(
            name: "SrokaDesign",
            dependencies: ["SrokaCore"],
            resources: [
                .process("Resources/Colors.xcassets"),
                .process("Resources/Fonts"),
                .process("Localizable.xcstrings"),
            ]
        ),
        // MARK: Data (A network, B database)
        .target(name: "SrokaNetwork", dependencies: ["SrokaCore", dependencies]),
        .target(
            name: "SrokaDatabase",
            dependencies: ["SrokaCore", dependencies, .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // MARK: Engine (G sync, H content, I session)
        .target(name: "SrokaSync", dependencies: ["SrokaCore", "SrokaNetwork", "SrokaDatabase", dependencies, clocks]),
        .target(
            name: "SrokaContent",
            dependencies: [
                "SrokaCore", "SrokaNetwork", "SrokaDatabase", dependencies,
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "SrokaSession",
            dependencies: [
                "SrokaCore", "SrokaNetwork", "SrokaDatabase", dependencies,
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // MARK: Features — features never depend on other features or on data/engine modules.
        .target(name: "AuthFeature", dependencies: featureDependencies, resources: featureResources),
        .target(name: "LibraryFeature", dependencies: featureDependencies, resources: featureResources),
        .target(name: "TagsFeature", dependencies: featureDependencies, resources: featureResources),
        .target(name: "SearchFeature", dependencies: featureDependencies, resources: featureResources),
        .target(name: "ReaderFeature", dependencies: featureDependencies, resources: featureResources),
        .target(name: "SettingsFeature", dependencies: featureDependencies, resources: featureResources),
        .target(name: "ShareFeature", dependencies: featureDependencies, resources: featureResources),
        // MARK: Tests
        .testTarget(name: "SrokaCoreTests", dependencies: testDependencies("SrokaCore")),
        .testTarget(name: "SrokaTestingTests", dependencies: testDependencies("SrokaTesting")),
        .testTarget(name: "SrokaDesignTests", dependencies: testDependencies("SrokaDesign")),
        .testTarget(name: "SrokaNetworkTests", dependencies: testDependencies("SrokaNetwork")),
        .testTarget(
            name: "SrokaDatabaseTests",
            dependencies: testDependencies("SrokaDatabase") + [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "SrokaSyncTests", dependencies: testDependencies("SrokaSync")),
        .testTarget(
            name: "SrokaContentTests",
            dependencies: testDependencies("SrokaContent") + [
                "SrokaDatabase", "SrokaNetwork", .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "SrokaSessionTests",
            dependencies: testDependencies("SrokaSession") + [
                "SrokaNetwork", "SrokaDatabase", .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "AuthFeatureTests", dependencies: testDependencies("AuthFeature")),
        .testTarget(name: "LibraryFeatureTests", dependencies: testDependencies("LibraryFeature")),
        .testTarget(name: "TagsFeatureTests", dependencies: testDependencies("TagsFeature")),
        .testTarget(name: "SearchFeatureTests", dependencies: testDependencies("SearchFeature")),
        .testTarget(name: "ReaderFeatureTests", dependencies: testDependencies("ReaderFeature")),
        .testTarget(name: "SettingsFeatureTests", dependencies: testDependencies("SettingsFeature")),
        .testTarget(name: "ShareFeatureTests", dependencies: testDependencies("ShareFeature")),
        .testTarget(
            name: "SnapshotTests",
            dependencies: [
                "SrokaDesign", "SrokaTesting", "AuthFeature", "LibraryFeature", "TagsFeature", "SearchFeature",
                "ReaderFeature", "SettingsFeature", "ShareFeature", dependencies,
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
