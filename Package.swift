// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeyCodex",
    platforms: [.macOS("14.4")],   // NSHostingMenu (status-item menu) needs 14.4+
    products: [
        .library(name: "HeyCodexKit", targets: ["HeyClaudeKit"]),
        // On-machine test harness: this CLT-only toolchain has no XCTest runner
        // (`xcrun --find xctest` fails), so the XCTest files in
        // Tests/HeyClaudeKitTests are retained for CI/Xcode while verification
        // here runs through this executable. See internal design notes.
        .executable(name: "hey-codex-selftest", targets: ["heyclaude-selftest"]),
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
            name: "HeyClaudeKit",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/HeyClaudeKit",
            linkerSettings: [
                // The static archive bundles onnxruntime + C++ code but not the
                // C++ runtime or system frameworks, so link them on the consumer.
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),
        .executableTarget(
            name: "heyclaude-selftest",
            dependencies: ["HeyClaudeKit"],
            path: "Sources/heyclaude-selftest"
        ),
        .executableTarget(
            name: "HeyCodexApp",
            dependencies: ["HeyClaudeKit"],
            path: "Sources/HeyClaudeApp",
            exclude: [
                "AccessibilityPermission.swift",
                "CommandExecutorHolder.swift",
                "Island",
                "LoginItem.swift",
                "Onboarding",
                "Preferences",
                "PushToTalkController.swift",
                "SystemSettingsLink.swift",
                "WakePhraseEnrollmentWindowController.swift"
            ],
            sources: [
                "AppController.swift",
                "FirstRunSetupWindowController.swift",
                "HeyClaudeApp.swift",
                "SettingsWindowController.swift",
                "WakeWordEngineHolder.swift"
            ]
        ),
        .testTarget(
            name: "HeyClaudeKitTests",
            dependencies: ["HeyClaudeKit"],
            path: "Tests/HeyClaudeKitTests",
            exclude: [
                "AppStateTests.swift",
                "CommandExecutorTests.swift",
                "CommandRegistryTests.swift",
                "CommandTests.swift",
                "EditorRoutingTests.swift",
                "IdeLockfileReaderTests.swift",
                "IslandModelTests.swift",
                "LauncherEscapingTests.swift",
                "ManualCaptureFlagTests.swift",
                "MascotCatalogTests.swift",
                "MascotGridTests.swift",
                "ParakeetTranscriberTests.swift",
                "PushToTalkKeyTests.swift",
                "RecentActionsTests.swift",
                "SettingsStoreTests.swift",
                "TerminalLauncherTests.swift",
                "WakeWordEngineTests.swift"
            ],
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
                "VoiceShortcutTests.swift",
                "WakeEnrollmentTests.swift",
                "WakePhraseTests.swift",
                "WakePrefixStripperTests.swift"
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
