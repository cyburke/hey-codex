// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeyCodex",
    platforms: [.macOS("14.4")],   // NSHostingMenu (status-item menu) needs 14.4+
    products: [
        .library(name: "HeyCodexKit", targets: ["HeyCodexKit"]),
        // On-machine test harness: this CLT-only toolchain has no XCTest runner
        // (`xcrun --find xctest` fails), so the XCTest files in
        // Tests/HeyCodexKitTests are retained for CI/Xcode while verification
        // here runs through this executable. See internal design notes.
        .executable(name: "hey-codex-selftest", targets: ["hey-codex-selftest"]),
        .executable(name: "HeyCodexApp", targets: ["HeyCodexApp"]),
    ],
    dependencies: [],
    targets: [
        // Prebuilt sherpa-onnx static xcframework (universal2 macOS).
        // Fetched + module map injected by `scripts/fetch-sherpa.sh` (gitignored);
        // see internal design notes for the reproducible setup.
        .binaryTarget(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx/sherpa-onnx.xcframework"
        ),
        // Bridges the BPE encoder inside the sherpa-onnx static library, which is
        // how keyword text becomes model tokens. Header-only here: the
        // implementation is already linked.
        .target(
            name: "CBpe",
            path: "Sources/CBpe",
            publicHeadersPath: "include",
            // The vendored encoder headers include each other by their upstream
            // path, and they must stay out of the public header directory or Swift
            // tries to import C++ into the module.
            cxxSettings: [.unsafeFlags(["-std=c++17", "-I", "Sources/CBpe"])]
        ),
        .target(
            name: "HeyCodexKit",
            dependencies: ["CSherpaOnnx", "CBpe"],
            path: "Sources/HeyCodexKit",
            linkerSettings: [
                // The static archive bundles onnxruntime + C++ code but not the
                // C++ runtime or system frameworks, so link them on the consumer.
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "hey-codex-selftest",
            dependencies: ["HeyCodexKit"],
            path: "Sources/hey-codex-selftest"
        ),
        .executableTarget(
            name: "HeyCodexApp",
            dependencies: ["HeyCodexKit"],
            path: "Sources/HeyCodexApp",
            sources: [
                "AppController.swift",
                "HeyCodexApp.swift",
                "SettingsWindowController.swift",
                "SetupWindowController.swift",
                "WakePhraseEnrollmentWindowController.swift",
                "WakeWordEngineHolder.swift"
            ]
        ),
        .testTarget(
            name: "HeyCodexKitTests",
            dependencies: ["HeyCodexKit"],
            path: "Tests/HeyCodexKitTests",
            sources: [
                "CodexSettingsTests.swift",
                "CaptureSessionTests.swift",
                "EnrollmentDiagnosticsTests.swift",
                "KeywordStoreTests.swift",
                "ProductWakePhraseTests.swift",
                "TestSupport.swift",
                "VoiceActivationLatchTests.swift",
                "VoiceActivationControllerTests.swift",
                "VoicePanelObserverTests.swift",
                "VoiceDetectionTrustTests.swift",
                "VoiceActivityDetectorTests.swift",
                "VoiceSessionTests.swift",
                "AudioInputSelectionTests.swift",
                "SetupStateTests.swift",
                "UpdateCheckTests.swift",
                "WakeCalibrationTests.swift",
                "VoiceShortcutTests.swift",
                "WakeEnrollmentTests.swift",
                "WakePhraseTests.swift",
                "WakePrefixStripperTests.swift"
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
