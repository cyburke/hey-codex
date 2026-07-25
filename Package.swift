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
        .target(
            name: "HeyCodexKit",
            dependencies: ["CSherpaOnnx"],
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
                "KeywordStoreTests.swift",
                "ProductWakePhraseTests.swift",
                "TestSupport.swift",
                "VoiceActivationLatchTests.swift",
                "VoiceActivationControllerTests.swift",
                "VoicePanelObserverTests.swift",
                "VoiceDetectionTrustTests.swift",
                "VoiceActivityDetectorTests.swift",
                "VoiceSessionTests.swift",
                "SetupStateTests.swift",
                "UpdateCheckTests.swift",
                "VoiceShortcutTests.swift",
                "WakeEnrollmentTests.swift",
                "WakePhraseTests.swift",
                "WakePrefixStripperTests.swift"
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
