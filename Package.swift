// swift-tools-version: 6.0
// NeMoTextNormalizationSwift — English TN via Sparrowhawk WFST runtime
import PackageDescription

let package = Package(
    name: "NeMoTextNormalizationSwift",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0"),  // macOS target so the test suite runs on host/CI
    ],
    products: [
        .library(
            name: "TextNormalization",
            targets: ["TextNormalization"]
        ),
    ],
    targets: [
        // Pre-built xcframework: merged static libs for OpenFst + Thrax + re2 +
        // protobuf + Sparrowhawk. Built by Scripts/build_sparrowhawk_ios.sh.
        .binaryTarget(
            name: "Sparrowhawk",
            path: "Frameworks/Sparrowhawk.xcframework"
        ),

        // ObjC++ shim: thin C wrapper over sparrowhawk::Normalizer so Swift
        // can call it without exposing raw C++/proto types.
        .target(
            name: "CSparrowhawk",
            dependencies: ["Sparrowhawk"],
            path: "Sources/CSparrowhawk",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
            ]
        ),

        // Pure-Swift facade + bundled grammar resources (FARs + ascii_proto config).
        .target(
            name: "TextNormalization",
            dependencies: ["CSparrowhawk"],
            path: "Sources/TextNormalization",
            resources: [
                // Copy the grammar directory to the bundle root (not inside
                // a Resources/ subdirectory). A Resources/ subdirectory causes
                // codesign to interpret the bundle as macOS-format and reject it
                // on iOS builds; placing assets at the root avoids this.
                .copy("Resources/en_tn_grammars_cased"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // Data-driven spec runner: reads upstream tilde-separated .txt fixtures
        // and asserts Normalizer output matches expected for each case.
        .testTarget(
            name: "TextNormalizationTests",
            dependencies: ["TextNormalization"],
            path: "Tests/TextNormalizationTests",
            resources: [
                .copy("Resources/data_text_normalization"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
