import XCTest
@testable import HeyCodexKit

final class UpdateCheckTests: XCTestCase {
    private let page = UpdateCheck.releasesPage

    func test_versionsCompareNumericallyNotAlphabetically() {
        // The bug this guards: "0.10.0" < "0.9.0" as text, which would tell every
        // user on 0.10 that 0.9 is an upgrade.
        XCTAssertTrue(ReleaseVersion("v0.9.0")! < ReleaseVersion("v0.10.0")!)
        XCTAssertTrue(ReleaseVersion("1.9.9")! < ReleaseVersion("1.10.0")!)
        XCTAssertFalse(ReleaseVersion("v2.0.0")! < ReleaseVersion("v1.99.99")!)
    }

    func test_missingTrailingComponentsCountAsZero() {
        XCTAssertEqual(ReleaseVersion("1.2")!, ReleaseVersion("1.2.0")!)
        XCTAssertTrue(ReleaseVersion("1.2")! < ReleaseVersion("1.2.1")!)
    }

    func test_prereleaseSuffixIsIgnoredForOrdering() {
        XCTAssertEqual(ReleaseVersion("1.0.0-beta.2")!, ReleaseVersion("1.0.0")!)
    }

    func test_rejectsUnparseableVersions() {
        XCTAssertNil(ReleaseVersion("latest"))
        XCTAssertNil(ReleaseVersion(""))
        XCTAssertNil(ReleaseVersion("v1.x.0"))
    }

    func test_newerReleaseIsOffered() {
        let status = UpdateCheck.status(currentVersion: "0.1.0",
                                        latestTag: "v0.2.0",
                                        releaseURL: page)
        XCTAssertEqual(status, .available(version: "v0.2.0", url: page))
    }

    func test_sameVersionIsUpToDate() {
        XCTAssertEqual(UpdateCheck.status(currentVersion: "0.1.0",
                                          latestTag: "v0.1.0",
                                          releaseURL: page), .upToDate)
    }

    func test_olderPublishedReleaseNeverOffersADowngrade() {
        // A local build ahead of the published tag must not be told to "update"
        // to something older.
        XCTAssertEqual(UpdateCheck.status(currentVersion: "0.3.0",
                                          latestTag: "v0.2.0",
                                          releaseURL: page), .upToDate)
    }

    func test_unreadableResponseFailsRatherThanClaimingUpToDate() {
        // A failed request is not evidence the user is current, and must never
        // be reported as though it were.
        guard case .failed = UpdateCheck.status(currentVersion: "0.1.0",
                                                latestTag: nil,
                                                releaseURL: nil) else {
            return XCTFail("a missing tag must report failure")
        }
        guard case .failed = UpdateCheck.status(currentVersion: "development build",
                                                latestTag: "v0.2.0",
                                                releaseURL: page) else {
            return XCTFail("an unversioned build must report failure")
        }
    }

    func test_parsesGitHubReleasePayload() {
        let json = """
        {"tag_name":"v0.4.1","html_url":"https://github.com/cyburke/hey-codex/releases/tag/v0.4.1"}
        """.data(using: .utf8)!
        let parsed = UpdateCheck.parse(json)
        XCTAssertEqual(parsed.tag, "v0.4.1")
        XCTAssertEqual(parsed.url?.absoluteString,
                       "https://github.com/cyburke/hey-codex/releases/tag/v0.4.1")
    }

    func test_parseSurvivesGarbageWithoutCrashing() {
        let parsed = UpdateCheck.parse(Data("not json".utf8))
        XCTAssertNil(parsed.tag)
        XCTAssertNil(parsed.url)
    }

    func test_automaticCheckIsRateLimitedToOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-90_000), now: now))
    }
}
