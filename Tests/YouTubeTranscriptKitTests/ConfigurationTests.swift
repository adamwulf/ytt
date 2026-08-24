import XCTest
@testable import YouTubeTranscriptKit

/// Covers the `configure(_:)` seam: that supplied headers actually reach the wire, that they reach it
/// from every fetch site, and that a late call is not silently ignored.
final class ConfigurationTests: XCTestCase {

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) TestAgent/1.0"

    /// Every request the stub intercepted, oldest first. Recorded rather than asserted inside the
    /// handler because the claim under test is about what went out, not about what came back.
    private static var recordedRequests: [URLRequest] = []

    override func setUp() {
        super.setUp()
        Self.recordedRequests = []
        StubURLProtocol.handler = { request in
            ConfigurationTests.recordedRequests.append(request)
            if WatchPageFixture.isPlayerRequest(request) {
                return StubURLProtocol.Stub(body: WatchPageFixture.playerResponseJSON())
            }
            if WatchPageFixture.isCaptionRequest(request) {
                return StubURLProtocol.Stub(body: "<transcript></transcript>")
            }
            return StubURLProtocol.Stub(body: WatchPageFixture.html())
        }
        // Installed through the kit's own seam rather than by assigning `session`, so the stub
        // survives the configure(_:) calls these tests make.
        YouTubeTranscriptKit.stubProtocolClasses = [StubURLProtocol.self]
    }

    override func tearDown() {
        YouTubeTranscriptKit.configure(.init())
        YouTubeTranscriptKit.stubProtocolClasses = nil
        StubURLProtocol.handler = nil
        Self.recordedRequests = []
        super.tearDown()
    }

    /// Runs one watch-page fetch for its side effect on the stub. Failures are ignored: these tests
    /// assert on the request that went out, not on the value that came back.
    private func fetch(includeTranscript: Bool = false) async {
        _ = try? await YouTubeTranscriptKit.getVideoInfo(url: WatchPageFixture.videoURL,
                                                         includeTranscript: includeTranscript)
    }

    private func header(_ field: String, ofRequestAt index: Int) -> String? {
        guard Self.recordedRequests.indices.contains(index) else { return nil }
        return Self.recordedRequests[index].value(forHTTPHeaderField: field)
    }

    // MARK: - Headers reach the wire

    func testConfiguredHeadersAreSentOnTheWatchPageRequest() async {
        YouTubeTranscriptKit.configure(.init(additionalHeaders: [
            "User-Agent": Self.userAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]))

        await fetch()

        XCTAssertEqual(Self.recordedRequests.count, 1)
        XCTAssertEqual(header("User-Agent", ofRequestAt: 0), Self.userAgent)
        XCTAssertEqual(header("Accept-Language", ofRequestAt: 0), "en-US,en;q=0.9")
    }

    func testConfiguredHeadersAreSentOnTheCaptionRequestToo() async throws {
        // The transcript fetch spans two call sites beyond the watch page: the InnerTube player POST
        // that now supplies the caption tracks, and the caption GET itself. Headers ride on the
        // session rather than on individual requests precisely so no site can be forgotten, so every
        // one of them must carry the configured identity.
        YouTubeTranscriptKit.configure(.init(additionalHeaders: ["User-Agent": Self.userAgent]))

        await fetch(includeTranscript: true)

        XCTAssertEqual(Self.recordedRequests.count, 3,
                       "Expected a watch page fetch, an InnerTube player fetch and a caption fetch")
        let playerRequest = try XCTUnwrap(Self.recordedRequests.first(where: WatchPageFixture.isPlayerRequest))
        let captionRequest = try XCTUnwrap(Self.recordedRequests.first(where: WatchPageFixture.isCaptionRequest))
        XCTAssertEqual(playerRequest.value(forHTTPHeaderField: "User-Agent"), Self.userAgent)
        XCTAssertEqual(captionRequest.value(forHTTPHeaderField: "User-Agent"), Self.userAgent)
    }

    // MARK: - Ordering

    func testConfigureAfterAFetchStillTakesEffect() async {
        // The session is built lazily, so a configure(_:) landing after the first request could
        // plausibly no-op. From a consumer's side that is indistinguishable from "the new header
        // didn't help", which would send them chasing the wrong problem.
        await fetch()
        XCTAssertNotEqual(header("User-Agent", ofRequestAt: 0), Self.userAgent)

        YouTubeTranscriptKit.configure(.init(additionalHeaders: ["User-Agent": Self.userAgent]))
        await fetch()

        XCTAssertEqual(Self.recordedRequests.count, 2)
        XCTAssertEqual(header("User-Agent", ofRequestAt: 1), Self.userAgent)
    }

    func testConfigureReplacesTheHeadersFromAnEarlierCall() async {
        YouTubeTranscriptKit.configure(.init(additionalHeaders: [
            "User-Agent": Self.userAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]))
        YouTubeTranscriptKit.configure(.init(additionalHeaders: ["User-Agent": "Replacement/2.0"]))

        await fetch()

        XCTAssertEqual(header("User-Agent", ofRequestAt: 0), "Replacement/2.0")
        XCTAssertNil(header("Accept-Language", ofRequestAt: 0),
                     "configure(_:) replaces the header set rather than merging into it")
    }

    // MARK: - Defaults

    func testDefaultConfigurationSendsNoHeadersOfItsOwn() async {
        // The kit ships no identity. A consumer that wants one supplies the whole coherent set.
        XCTAssertTrue(YouTubeTranscriptKit.configuration.additionalHeaders.isEmpty)

        await fetch()

        XCTAssertEqual(Self.recordedRequests.count, 1)
        XCTAssertNil(header("Accept-Language", ofRequestAt: 0))
        XCTAssertNotEqual(header("User-Agent", ofRequestAt: 0), Self.userAgent)
    }

    func testConfigurationReadsBackWhatWasSet() {
        YouTubeTranscriptKit.configure(.init(additionalHeaders: ["User-Agent": Self.userAgent]))

        XCTAssertEqual(YouTubeTranscriptKit.configuration.additionalHeaders, ["User-Agent": Self.userAgent])
    }

    // MARK: - The existing test seam still works

    func testAssigningSessionDirectlyStillOverridesTheKitSession() async {
        // StubbedFetchTests installs its stub this way, so configure(_:) must not have broken it.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["User-Agent": "DirectlyAssigned/1.0"]
        YouTubeTranscriptKit.session = URLSession(configuration: config)

        await fetch()

        XCTAssertEqual(header("User-Agent", ofRequestAt: 0), "DirectlyAssigned/1.0")
    }
}
