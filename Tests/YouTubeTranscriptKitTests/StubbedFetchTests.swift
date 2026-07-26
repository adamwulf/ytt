import XCTest
@testable import YouTubeTranscriptKit

/// Serves canned responses so the fetch paths can be exercised without touching the network.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        /// The final URL after redirects, which is what URLSession reports. Defaults to the request URL.
        let url: URL?
        let body: String

        init(statusCode: Int = 200, url: URL? = nil, body: String = "") {
            self.statusCode = statusCode
            self.url = url
            self.body = body
        }
    }

    /// Consulted for every intercepted request.
    static var handler: ((URLRequest) -> Stub)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler, let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let stub = handler(request)
        // The stub reports the post-redirect state directly: URLSession would have followed the 302
        // itself and handed back a response whose url is the CAPTCHA wall.
        guard let response = HTTPURLResponse(url: stub.url ?? requestURL,
                                             statusCode: stub.statusCode,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Canned YouTube payloads, shared by every test that needs a fetch to get somewhere.
enum WatchPageFixture {

    // UnicodeScalar(59) produces the semicolon that terminates the player response script block
    private static let sc = String(UnicodeScalar(59))

    static let videoURL = URL(string: "https://www.youtube.com/watch?v=abc123")!
    static let captionURL = URL(string: "https://www.youtube.com/api/timedtext?v=abc123")!
    static let captchaURL = URL(string: "https://www.google.com/sorry/index?continue=https://www.youtube.com/watch%3Fv%3Dabc123")!

    static func isCaptionRequest(_ request: URLRequest) -> Bool {
        return request.url?.path.contains("timedtext") == true
    }

    /// A watch page that parses cleanly and advertises one caption track, so the caption fetch runs.
    static func html() -> String {
        return "<html><script>var ytInitialPlayerResponse = "
            + "{\"videoDetails\":{\"videoId\":\"abc123\",\"title\":\"Test Video\","
            + "\"lengthSeconds\":\"120\",\"channelId\":\"UCtest\","
            + "\"shortDescription\":\"A test video\",\"viewCount\":\"1000\","
            + "\"author\":\"Test Author\","
            + "\"thumbnail\":{\"thumbnails\":[{\"url\":\"https://i.ytimg.com/vi/abc123/default.jpg\","
            + "\"width\":120,\"height\":90}]},\"isLiveContent\":false},"
            + "\"microformat\":{\"playerMicroformatRenderer\":{\"title\":{\"runs\":[{\"text\":\"Test Video\"}]},"
            + "\"lengthSeconds\":\"120\",\"externalChannelId\":\"UCtest\","
            + "\"category\":\"Education\","
            + "\"publishDate\":\"2024-01-15T00:00:00\","
            + "\"uploadDate\":\"2024-01-15T00:00:00\","
            + "\"ownerChannelName\":\"Test Author\","
            + "\"ownerProfileUrl\":\"https://www.youtube.com/channel/UCtest\"}},"
            + "\"captions\":{\"playerCaptionsTracklistRenderer\":{\"captionTracks\":["
            + "{\"baseUrl\":\"\(captionURL.absoluteString)\",\"vssId\":\".en\",\"languageCode\":\"en\"}]}}}"
            + "\(sc)</script></html>"
    }
}

final class StubbedFetchTests: XCTestCase {

    private static let videoURL = WatchPageFixture.videoURL
    private static let captionURL = WatchPageFixture.captionURL
    private static let captchaURL = WatchPageFixture.captchaURL

    private var originalSession: URLSession!

    override func setUp() {
        super.setUp()
        originalSession = YouTubeTranscriptKit.session
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        YouTubeTranscriptKit.session = URLSession(configuration: config)
    }

    override func tearDown() {
        YouTubeTranscriptKit.session = originalSession
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private static func watchPageHTML() -> String {
        return WatchPageFixture.html()
    }

    private static func isCaptionRequest(_ request: URLRequest) -> Bool {
        return WatchPageFixture.isCaptionRequest(request)
    }

    private func assertRateLimited(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? YouTubeTranscriptKit.TranscriptError else {
            return XCTFail("Expected TranscriptError, got \(error)", file: file, line: line)
        }
        // Deliberately the same plain pattern hunch uses, so a wrapped error fails this test.
        guard case .rateLimited = error else {
            return XCTFail("Expected .rateLimited unwrapped, got \(error)", file: file, line: line)
        }
    }

    // MARK: - The ban must survive every layer between the fetch and the caller

    func testCaptionFetchHittingCaptchaWallSurfacesRateLimited() async {
        // The mid-run ban: the watch page was already fetched, then the ban begins and the caption
        // fetch lands on the CAPTCHA wall. Returning a VideoInfo here would look like a success and
        // callers would persist a video as done with a transcript it actually has.
        StubURLProtocol.handler = { request in
            if Self.isCaptionRequest(request) {
                return StubURLProtocol.Stub(statusCode: 200, url: Self.captchaURL, body: "<html>302 Moved</html>")
            }
            return StubURLProtocol.Stub(body: Self.watchPageHTML())
        }

        do {
            let info = try await YouTubeTranscriptKit.getVideoInfo(url: Self.videoURL, includeTranscript: true)
            XCTFail("Expected .rateLimited, but got a VideoInfo with transcript \(String(describing: info.transcript))")
        } catch {
            assertRateLimited(error)
        }
    }

    func testWatchPageHittingCaptchaWallSurfacesRateLimited() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Stub(statusCode: 200, url: Self.captchaURL, body: "<html>302 Moved</html>")
        }

        do {
            _ = try await YouTubeTranscriptKit.getVideoInfo(url: Self.videoURL, includeTranscript: true)
            XCTFail("Expected .rateLimited")
        } catch {
            assertRateLimited(error)
        }
    }

    func testGetTranscriptHittingCaptchaWallSurfacesRateLimited() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Stub(statusCode: 200, url: Self.captchaURL, body: "<html>302 Moved</html>")
        }

        do {
            _ = try await YouTubeTranscriptKit.getTranscript(url: Self.videoURL)
            XCTFail("Expected .rateLimited")
        } catch {
            assertRateLimited(error)
        }
    }

    func testCaptionFetchServerErrorSurfacesHTTPError() async {
        // 5xx is transient, so it must fail the call rather than quietly drop the transcript.
        StubURLProtocol.handler = { request in
            if Self.isCaptionRequest(request) {
                return StubURLProtocol.Stub(statusCode: 503)
            }
            return StubURLProtocol.Stub(body: Self.watchPageHTML())
        }

        do {
            _ = try await YouTubeTranscriptKit.getVideoInfo(url: Self.videoURL, includeTranscript: true)
            XCTFail("Expected .httpError")
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            guard case .httpError(let statusCode, _) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Permanently missing captions must not fail the video

    func testCaptionFetchNotFoundStillReturnsVideoInfo() async throws {
        // A caption track that is gone stays gone. Throwing here would strand the video: callers
        // that only mark a video done on success would retry it every run and never drain.
        StubURLProtocol.handler = { request in
            if Self.isCaptionRequest(request) {
                return StubURLProtocol.Stub(statusCode: 404)
            }
            return StubURLProtocol.Stub(body: Self.watchPageHTML())
        }

        let info = try await YouTubeTranscriptKit.getVideoInfo(url: Self.videoURL, includeTranscript: true)
        XCTAssertEqual(info.videoId, "abc123")
        XCTAssertNil(info.transcript, "A permanently unavailable caption degrades to a nil transcript")
    }

    func testCaptionFetchForbiddenStillReturnsVideoInfo() async throws {
        StubURLProtocol.handler = { request in
            if Self.isCaptionRequest(request) {
                return StubURLProtocol.Stub(statusCode: 403)
            }
            return StubURLProtocol.Stub(body: Self.watchPageHTML())
        }

        let info = try await YouTubeTranscriptKit.getVideoInfo(url: Self.videoURL, includeTranscript: true)
        XCTAssertEqual(info.videoId, "abc123")
        XCTAssertNil(info.transcript)
    }

    // MARK: - The happy path still works

    func testTranscriptIsReturnedWhenCaptionFetchSucceeds() async throws {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><transcript>"
            + "<text start=\"0.0\" dur=\"1.5\">Hello there</text>"
            + "<text start=\"1.5\" dur=\"2.0\">General Kenobi</text></transcript>"

        StubURLProtocol.handler = { request in
            if Self.isCaptionRequest(request) {
                return StubURLProtocol.Stub(body: xml)
            }
            return StubURLProtocol.Stub(body: Self.watchPageHTML())
        }

        let info = try await YouTubeTranscriptKit.getVideoInfo(url: Self.videoURL, includeTranscript: true)
        XCTAssertEqual(info.videoId, "abc123")
        XCTAssertEqual(info.transcript?.count, 2)
        XCTAssertEqual(info.transcript?.first?.text, "Hello there")
    }

    func testVideoInfoWithoutTranscriptSkipsCaptionFetch() async throws {
        // With includeTranscript false a banned caption endpoint must not matter at all.
        StubURLProtocol.handler = { request in
            if Self.isCaptionRequest(request) {
                return StubURLProtocol.Stub(statusCode: 200, url: Self.captchaURL, body: "<html>302 Moved</html>")
            }
            return StubURLProtocol.Stub(body: Self.watchPageHTML())
        }

        let info = try await YouTubeTranscriptKit.getVideoInfo(url: Self.videoURL, includeTranscript: false)
        XCTAssertEqual(info.videoId, "abc123")
        XCTAssertNil(info.transcript)
    }
}
