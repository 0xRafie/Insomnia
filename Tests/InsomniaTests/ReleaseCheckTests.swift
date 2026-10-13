import Foundation
import XCTest
@testable import Insomnia

/// Stands in for GitHub's releases endpoint: the JSON or the failure the
/// next request gets, and how many requests were made.
private actor FakeReleases: ReleaseFetching {
    private let answer: Result<Data, ReleaseCheckError>
    private let gate: AsyncGate?
    private(set) var requests = 0

    init(_ answer: Result<Data, ReleaseCheckError>, gate: AsyncGate? = nil) {
        self.answer = answer
        self.gate = gate
    }

    func releases() async throws -> Data {
        requests += 1
        if let gate { await gate.wait() }
        return try answer.get()
    }
}

/// The version line and the update check, without a window and without a
/// network: the fetcher is a fake, and the report is a pure function of
/// the installed version and the releases list.
final class ReleaseCheckTests: XCTestCase {
    private var home: TempHome!

    override func setUp() {
        super.setUp()
        home = TempHome()
    }

    override func tearDown() {
        home.destroy()
        home = nil
        super.tearDown()
    }

    // MARK: The installed version

    func testVersionAndBuildComeFromInfoPlist() {
        let build = AppBuild(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"])
        XCTAssertEqual(build, AppBuild(version: "0.1.0", build: "1"))
        XCTAssertEqual(build.label, "0.1.0 (1)")
    }

    func testABinaryWithoutAnInfoPlistSaysSo() {
        let build = AppBuild(info: [:])
        XCTAssertNil(build.version)
        XCTAssertEqual(build.label, "no version: this build has no Info.plist")
        XCTAssertEqual(AppBuild(info: ["CFBundleShortVersionString": "", "CFBundleVersion": 7]).label, "no version: this build has no Info.plist",
                       "an empty version and a build of the wrong type read as missing")
        XCTAssertEqual(AppBuild(info: ["CFBundleShortVersionString": "0.2.0"]).label, "0.2.0")
    }

    // MARK: Tags

    func testStableAndNightlyTagsParseAndOthersDoNot() {
        XCTAssertEqual(ReleaseTag("v0.1.0"), .stable(SemanticVersion(0, 1, 0)))
        XCTAssertEqual(ReleaseTag("v1.10.2"), .stable(SemanticVersion(1, 10, 2)))
        XCTAssertEqual(ReleaseTag("nightly-20261012-db9085ea12a8"), .nightly(date: "20261012", commit: "db9085ea12a8"))
        for name in ["0.1.0", "v0.1", "v0.1.0.1", "v0.1.0-rc1", "V0.1.0", "v0.1.a", "v١.0.0",
                     "nightly-2026101-db9085ea12a8", "nightly-20261012-DB9085EA12A8", "nightly-20261012-db9085ea12a",
                     "nightly-20261012-db9085ea12a8-2", "stable-0.1.0", ""] {
            XCTAssertNil(ReleaseTag(name), name)
        }
    }

    func testVersionsCompareNumericallyNotAsText() {
        XCTAssertLessThan(SemanticVersion("0.9.9")!, SemanticVersion("0.10.0")!)
        XCTAssertLessThan(SemanticVersion("1.2.3")!, SemanticVersion("1.2.10")!)
        XCTAssertLessThan(SemanticVersion("1.9.9")!, SemanticVersion("2.0.0")!)
        XCTAssertEqual(SemanticVersion("0.1.0"), SemanticVersion(0, 1, 0))
        XCTAssertEqual("\(SemanticVersion(1, 10, 2))", "1.10.2")
    }

    // MARK: The report

    private let installed = AppBuild(version: "0.1.0", build: "1")

    private func release(_ tag: String, prerelease: Bool, draft: Bool = false, published: String? = nil) -> GitHubRelease {
        GitHubRelease(tagName: tag, prerelease: prerelease, draft: draft, publishedAt: published)
    }

    func testANewerStableReleaseIsReported() {
        let report = ReleaseReport(installed: installed, releases: [
            release("nightly-20261012-db9085ea12a8", prerelease: true),
            release("v0.2.0", prerelease: false),
            release("v0.1.0", prerelease: false),
        ])

        XCTAssertEqual(report.standing, .newerStableAvailable)
        XCTAssertEqual(report.newestStable, SemanticVersion(0, 2, 0))
        XCTAssertEqual(report.newestNightly, "nightly-20261012-db9085ea12a8")
        XCTAssertEqual(report.summary, "A newer stable release exists: 0.2.0. You have 0.1.0. Newest nightly: nightly-20261012-db9085ea12a8.")
        XCTAssertEqual(report.logLine, "installed 0.1.0 (1), newest stable 0.2.0, newest nightly nightly-20261012-db9085ea12a8: newer stable release available")
    }

    /// GitHub lists releases newest first, but the newest stable is the
    /// highest version, not the first entry: a patch release of an older
    /// line can be published after a newer line's release.
    func testTheNewestStableIsTheHighestVersionNotTheFirstEntry() {
        let report = ReleaseReport(installed: installed, releases: [
            release("v0.1.1", prerelease: false),
            release("v0.2.0", prerelease: false),
        ])

        XCTAssertEqual(report.newestStable, SemanticVersion(0, 2, 0))
    }

    func testTheInstalledVersionCanBeTheNewestStable() {
        let report = ReleaseReport(installed: installed, releases: [
            release("v0.1.0", prerelease: false),
            release("nightly-20261011-2c116dd6399c", prerelease: true),
        ])

        XCTAssertEqual(report.standing, .upToDate)
        XCTAssertEqual(report.summary, "You have the newest stable release, 0.1.0. Newest nightly: nightly-20261011-2c116dd6399c.")
    }

    /// A nightly reports the version Info.plist has on main, which is above
    /// the stable one once main bumps it. That is not an update.
    func testAVersionAboveTheNewestStableIsNotBehind() {
        let report = ReleaseReport(installed: AppBuild(version: "0.2.0", build: "1"), releases: [
            release("v0.1.0", prerelease: false),
        ])

        XCTAssertEqual(report.standing, .aheadOfStable)
        XCTAssertEqual(report.summary, "You have 0.2.0, above the newest stable release, 0.1.0. That is a nightly or a source build. No nightly is published.")
    }

    func testDraftsPrereleasesWithStableTagsAndForeignTagsAreNotStableReleases() {
        let report = ReleaseReport(installed: installed, releases: [
            release("v0.3.0", prerelease: false, draft: true),
            release("v0.2.0", prerelease: true),
            release("0.4.0", prerelease: false),
            release("v0.1.0", prerelease: false),
            release("nightly-20261012-db9085ea12a8", prerelease: false),
            release("nightly-20261013-0123456789ab", prerelease: true, draft: true),
        ])

        XCTAssertEqual(report.newestStable, SemanticVersion(0, 1, 0), "a draft, a prerelease and a tag without the v are not the newest stable")
        XCTAssertNil(report.newestNightly, "a nightly tag not marked prerelease, and a draft, are not the newest nightly")
    }

    func testTheNewestNightlyIsTheLatestDateThenTheLatestPublishedTime() {
        let report = ReleaseReport(installed: installed, releases: [
            release("nightly-20261011-2c116dd6399c", prerelease: true, published: "2026-10-11T14:16:27Z"),
            release("nightly-20261012-0123456789ab", prerelease: true, published: "2026-10-12T09:00:00Z"),
            release("nightly-20261012-db9085ea12a8", prerelease: true, published: "2026-10-12T17:00:11Z"),
            release("v0.1.0", prerelease: false),
        ])

        XCTAssertEqual(report.newestNightly, "nightly-20261012-db9085ea12a8")
    }

    func testNoStableReleaseYet() {
        let report = ReleaseReport(installed: installed, releases: [
            release("nightly-20261012-db9085ea12a8", prerelease: true),
        ])

        XCTAssertEqual(report.standing, .noStableRelease)
        XCTAssertEqual(report.summary, "No stable release is published yet. Newest nightly: nightly-20261012-db9085ea12a8.")
        XCTAssertEqual(ReleaseReport(installed: installed, releases: []).summary, "No stable release is published yet. No nightly is published.")
    }

    func testABuildWithoutAVersionStillLearnsTheNewestTags() {
        let unpackaged = ReleaseReport(installed: AppBuild(version: nil, build: nil), releases: [
            release("v0.1.0", prerelease: false),
        ])
        let odd = ReleaseReport(installed: AppBuild(version: "0.1", build: "1"), releases: [
            release("v0.1.0", prerelease: false),
        ])

        XCTAssertEqual(unpackaged.standing, .installedVersionUnknown)
        XCTAssertEqual(unpackaged.summary, "This build has no version to compare. The newest stable release is 0.1.0. No nightly is published.")
        XCTAssertEqual(odd.standing, .installedVersionUnknown, "a version that is not major.minor.patch cannot be compared")
    }

    // MARK: The answer from GitHub

    func testTheReleasesListDecodesFromGitHubsFields() throws {
        let json = """
        [
          {"tag_name": "nightly-20261012-db9085ea12a8", "name": "Insomnia nightly 2026-10-12 (db9085ea12a8)", "draft": false, "prerelease": true, "published_at": "2026-10-12T17:00:11Z", "html_url": "https://github.com/krishhgg/Insomnia/releases/tag/nightly-20261012-db9085ea12a8", "assets": []},
          {"tag_name": "v0.1.0", "name": "Insomnia 0.1.0 (stable)", "draft": false, "prerelease": false, "published_at": "2026-10-10T17:42:47Z", "html_url": "https://github.com/krishhgg/Insomnia/releases/tag/v0.1.0", "assets": []}
        ]
        """

        let releases = try ReleaseChecker.decode(Data(json.utf8))

        XCTAssertEqual(releases, [
            GitHubRelease(tagName: "nightly-20261012-db9085ea12a8", prerelease: true, publishedAt: "2026-10-12T17:00:11Z"),
            GitHubRelease(tagName: "v0.1.0", prerelease: false, publishedAt: "2026-10-10T17:42:47Z"),
        ])
    }

    func testAnAnswerThatIsNotAReleasesListIsOneError() {
        for body in ["{\"message\": \"API rate limit exceeded\"}", "<html>", "", "[{\"tag_name\": 1}]"] {
            XCTAssertThrowsError(try ReleaseChecker.decode(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ReleaseCheckError, .unexpectedAnswer)
            }
        }
    }

    func testTheRequestIsOneUnauthenticatedGetOfTheReleasesList() {
        let request = GitHubReleaseFetcher.request(installed: installed)

        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/krishhgg/Insomnia/releases?per_page=30")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Insomnia/0.1.0")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(GitHubReleaseFetcher.request(installed: AppBuild(version: nil, build: nil)).value(forHTTPHeaderField: "User-Agent"), "Insomnia/unpackaged")
        XCTAssertEqual(GitHubReleaseFetcher.releasesPage.absoluteString, "https://github.com/krishhgg/Insomnia/releases")
    }

    // MARK: The button

    private func json(_ releases: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: releases)
    }

    @MainActor
    func testAClickReportsTheNewestReleasesAndLogsThem() async throws {
        let data = try json([
            ["tag_name": "v0.2.0", "draft": false, "prerelease": false, "published_at": "2026-10-20T10:00:00Z"],
            ["tag_name": "v0.1.0", "draft": false, "prerelease": false, "published_at": "2026-10-10T17:42:47Z"],
        ])
        let fake = FakeReleases(.success(data))
        let checker = ReleaseChecker(fetcher: fake, installed: installed)
        XCTAssertEqual(checker.state, .idle)

        checker.check()
        XCTAssertEqual(checker.state, .checking)
        await checker.finish()

        XCTAssertEqual(checker.state, .checked(ReleaseReport(installed: installed, newestStable: SemanticVersion(0, 2, 0), newestNightly: nil)))
        let requests = await fake.requests
        XCTAssertEqual(requests, 1)
        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("[info] insomnia: release check: asking GitHub for the releases list"), log)
        XCTAssertTrue(log.contains("[info] insomnia: release check: installed 0.1.0 (1), newest stable 0.2.0, newest nightly none: newer stable release available"), log)
    }

    @MainActor
    func testAFailedRequestShowsItsReasonAndLogsIt() async throws {
        let checker = ReleaseChecker(fetcher: FakeReleases(.failure(.status(403))), installed: installed)

        checker.check()
        await checker.finish()

        XCTAssertEqual(checker.state, .failed("GitHub answered HTTP 403"))
        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("[error] insomnia: release check failed: GitHub answered HTTP 403"), log)
    }

    @MainActor
    func testAnAnswerThatIsNotAListFailsTheCheck() async throws {
        let checker = ReleaseChecker(fetcher: FakeReleases(.success(Data("{\"message\":\"API rate limit exceeded\"}".utf8))), installed: installed)

        checker.check()
        await checker.finish()

        XCTAssertEqual(checker.state, .failed("GitHub's answer was not a releases list"))
    }

    /// A second click while the request is in flight makes no second
    /// request; a click after the answer does.
    @MainActor
    func testAClickDuringACheckMakesNoSecondRequest() async throws {
        let gate = AsyncGate()
        let data = try json([["tag_name": "v0.1.0", "draft": false, "prerelease": false]])
        let fake = FakeReleases(.success(data), gate: gate)
        let checker = ReleaseChecker(fetcher: fake, installed: installed)

        checker.check()
        await gate.waitUntilStarted()
        checker.check()
        var requests = await fake.requests
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(checker.state, .checking)

        await gate.open()
        await checker.finish()
        XCTAssertEqual(checker.state, .checked(ReleaseReport(installed: installed, newestStable: SemanticVersion(0, 1, 0), newestNightly: nil)))

        checker.check()
        await checker.finish()
        requests = await fake.requests
        XCTAssertEqual(requests, 2)
    }
}
