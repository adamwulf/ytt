import XCTest
@testable import YouTubeTranscriptKit

final class TranscriptTests: XCTestCase {

    // UnicodeScalar(59) produces the semicolon character for use in HTML entity strings
    private static let sc = String(UnicodeScalar(59))

    // MARK: - parseTranscriptXML Unit Tests

    func testParseTranscriptXMLBasic() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>
        <transcript>
        <text start="0.0" dur="5.2">Hello world</text>
        <text start="5.2" dur="3.1">This is a test</text>
        </transcript>
        """

        let moments = try YouTubeTranscriptKit.parseTranscriptXML(xml)
        XCTAssertEqual(moments.count, 2)

        XCTAssertEqual(moments[0].start, 0.0)
        XCTAssertEqual(moments[0].duration, 5.2)
        XCTAssertEqual(moments[0].text, "Hello world")

        XCTAssertEqual(moments[1].start, 5.2)
        XCTAssertEqual(moments[1].duration, 3.1)
        XCTAssertEqual(moments[1].text, "This is a test")
    }

    func testParseTranscriptXMLWithHTMLEntities() throws {
        let sc = Self.sc
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>"
            + "<transcript>"
            + "<text start=\"1.0\" dur=\"2.0\">Tom &amp\(sc) Jerry</text>"
            + "<text start=\"3.0\" dur=\"2.5\">5 &lt\(sc) 10 &gt\(sc) 3</text>"
            + "<text start=\"5.5\" dur=\"1.0\">&quot\(sc)quoted&quot\(sc)</text>"
            + "</transcript>"

        let moments = try YouTubeTranscriptKit.parseTranscriptXML(xml)
        XCTAssertEqual(moments.count, 3)
        XCTAssertEqual(moments[0].text, "Tom & Jerry")
        XCTAssertEqual(moments[1].text, "5 < 10 > 3")
        XCTAssertEqual(moments[2].text, "\"quoted\"")
    }

    func testParseTranscriptXMLWithNumericEntities() throws {
        let sc = Self.sc
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>"
            + "<transcript>"
            + "<text start=\"0.0\" dur=\"1.0\">Hello&#39\(sc)s world</text>"
            + "</transcript>"

        let moments = try YouTubeTranscriptKit.parseTranscriptXML(xml)
        XCTAssertEqual(moments.count, 1)
        XCTAssertEqual(moments[0].text, "Hello's world")
    }

    func testParseTranscriptXMLEmptyThrows() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>
        <transcript>
        </transcript>
        """

        XCTAssertThrowsError(try YouTubeTranscriptKit.parseTranscriptXML(xml)) { error in
            guard let transcriptError = error as? YouTubeTranscriptKit.TranscriptError else {
                XCTFail("Expected TranscriptError, got \(error)")
                return
            }
            if case .noTranscriptData = transcriptError {
                // expected
            } else {
                XCTFail("Expected .noTranscriptData, got \(transcriptError)")
            }
        }
    }

    func testParseTranscriptXMLFractionalTimestamps() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>
        <transcript>
        <text start="123.456" dur="7.89">Some text</text>
        </transcript>
        """

        let moments = try YouTubeTranscriptKit.parseTranscriptXML(xml)
        XCTAssertEqual(moments.count, 1)
        XCTAssertEqual(moments[0].start, 123.456, accuracy: 0.001)
        XCTAssertEqual(moments[0].duration, 7.89, accuracy: 0.001)
    }

    func testParseTranscriptXMLMultipleMoments() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>
        <transcript>
        <text start="0.0" dur="2.0">First</text>
        <text start="2.0" dur="2.0">Second</text>
        <text start="4.0" dur="2.0">Third</text>
        <text start="6.0" dur="2.0">Fourth</text>
        <text start="8.0" dur="2.0">Fifth</text>
        </transcript>
        """

        let moments = try YouTubeTranscriptKit.parseTranscriptXML(xml)
        XCTAssertEqual(moments.count, 5)
        XCTAssertEqual(moments[0].text, "First")
        XCTAssertEqual(moments[4].text, "Fifth")
    }

    // MARK: - extractCaptionTracks Unit Tests

    func testExtractCaptionTracksFromHTML() throws {
        let sc = Self.sc
        let html = "<html><script>var ytInitialPlayerResponse = "
            + "{\"captions\":{\"playerCaptionsTracklistRenderer\":{\"captionTracks\":"
            + "[{\"baseUrl\":\"https://www.youtube.com/api/timedtext?v=test123&lang=en\","
            + "\"vssId\":\".en\",\"languageCode\":\"en\"}]}},"
            + "\"videoDetails\":{\"videoId\":\"test123\"}}\(sc)</script></html>"

        let tracks = try YouTubeTranscriptKit.extractCaptionTracks(from: html)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].languageCode, "en")
        XCTAssertEqual(tracks[0].vssId, ".en")
        XCTAssertTrue(tracks[0].baseUrl.contains("timedtext"))
    }

    func testExtractCaptionTracksEnglishFirst() throws {
        let sc = Self.sc
        let html = "<html><script>var ytInitialPlayerResponse = "
            + "{\"captions\":{\"playerCaptionsTracklistRenderer\":{\"captionTracks\":"
            + "[{\"baseUrl\":\"https://example.com/fr\",\"vssId\":\".fr\",\"languageCode\":\"fr\"},"
            + "{\"baseUrl\":\"https://example.com/en\",\"vssId\":\".en\",\"languageCode\":\"en\"}]}},"
            + "\"videoDetails\":{\"videoId\":\"test123\"}}\(sc)</script></html>"

        let tracks = try YouTubeTranscriptKit.extractCaptionTracks(from: html)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].languageCode, "en")
        XCTAssertEqual(tracks[1].languageCode, "fr")
    }

    func testExtractCaptionTracksPreferNonAutoGenerated() throws {
        let sc = Self.sc
        // Tracks with vssId starting with "a" are auto-generated
        // Non-"a" tracks should come first
        let html = "<html><script>var ytInitialPlayerResponse = "
            + "{\"captions\":{\"playerCaptionsTracklistRenderer\":{\"captionTracks\":"
            + "[{\"baseUrl\":\"https://example.com/auto\",\"vssId\":\"a.en\",\"languageCode\":\"en\"},"
            + "{\"baseUrl\":\"https://example.com/manual\",\"vssId\":\".en\",\"languageCode\":\"en\"}]}},"
            + "\"videoDetails\":{\"videoId\":\"test123\"}}\(sc)</script></html>"

        let tracks = try YouTubeTranscriptKit.extractCaptionTracks(from: html)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].vssId, ".en")
        XCTAssertEqual(tracks[1].vssId, "a.en")
    }

    func testExtractCaptionTracksNoCaptionsThrows() throws {
        let sc = Self.sc
        let html = "<html><script>var ytInitialPlayerResponse = "
            + "{\"videoDetails\":{\"videoId\":\"test123\"}}\(sc)</script></html>"

        XCTAssertThrowsError(try YouTubeTranscriptKit.extractCaptionTracks(from: html)) { error in
            guard let transcriptError = error as? YouTubeTranscriptKit.TranscriptError else {
                XCTFail("Expected TranscriptError, got \(error)")
                return
            }
            if case .noCaptionData = transcriptError {
                // expected
            } else {
                XCTFail("Expected .noCaptionData, got \(transcriptError)")
            }
        }
    }

    func testExtractCaptionTracksNoPlayerResponse() throws {
        let html = "<html><body>No player response here</body></html>"

        XCTAssertThrowsError(try YouTubeTranscriptKit.extractCaptionTracks(from: html)) { error in
            guard let transcriptError = error as? YouTubeTranscriptKit.TranscriptError else {
                XCTFail("Expected TranscriptError, got \(error)")
                return
            }
            if case .noCaptionData = transcriptError {
                // expected
            } else {
                XCTFail("Expected .noCaptionData, got \(transcriptError)")
            }
        }
    }

    // MARK: - extractVideoInfo Unit Tests

    func testExtractVideoInfoFromHTML() async throws {
        let sc = Self.sc
        let html = "<html><script>var ytInitialPlayerResponse = "
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
            + "\"ownerProfileUrl\":\"https://www.youtube.com/channel/UCtest\"}}}\(sc)</script></html>"

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: html, includeTranscript: false)
        XCTAssertEqual(info.videoId, "abc123")
        XCTAssertEqual(info.title, "Test Video")
        XCTAssertEqual(info.channelId, "UCtest")
        XCTAssertEqual(info.channelName, "Test Author")
        XCTAssertEqual(info.description, "A test video")
        XCTAssertEqual(info.viewCount, 1000)
        XCTAssertEqual(info.duration, 120)
        XCTAssertEqual(info.category, "Education")
        XCTAssertNil(info.transcript)
    }

    func testExtractVideoInfoNoPlayerResponseThrows() async {
        let html = "<html><body>Nothing here</body></html>"

        do {
            _ = try await YouTubeTranscriptKit.extractVideoInfo(from: html, includeTranscript: false)
            XCTFail("Expected noVideoInfo error")
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            if case .noVideoInfo = error {
                // expected
            } else {
                XCTFail("Expected .noVideoInfo, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testExtractVideoInfoMalformedPlayerResponseThrowsParseError() async {
        let sc = Self.sc
        // The marker is present but the payload does not match the expected schema, which is what a
        // YouTube markup change looks like. That must not masquerade as a missing video.
        let html = "<html><script>var ytInitialPlayerResponse = "
            + "{\"videoDetails\":{\"unexpectedKey\":true}}\(sc)</script></html>"

        do {
            _ = try await YouTubeTranscriptKit.extractVideoInfo(from: html, includeTranscript: false)
            XCTFail("Expected videoInfoParseError")
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            if case .videoInfoParseError(let underlying) = error {
                XCTAssertTrue(underlying is DecodingError, "Expected the decode failure to be carried out, got \(underlying)")
            } else {
                XCTFail("Expected .videoInfoParseError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Rate Limit Detection Unit Tests

    private func makeResponse(urlString: String, statusCode: Int) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(URL(string: urlString))
        return try XCTUnwrap(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil))
    }

    func testCaptchaWallRedirectIsRateLimited() throws {
        // The real shape of the ban: URLSession follows the 302 to Google's "unusual traffic" wall,
        // so the status we see is 200 and only the final URL gives it away.
        let response = try makeResponse(
            urlString: "https://www.google.com/sorry/index?continue=https://www.youtube.com/watch%3Fv%3Dh0EGCnBjTVk&q=abc",
            statusCode: 200
        )

        XCTAssertThrowsError(try YouTubeTranscriptKit.validate(response)) { error in
            guard let error = error as? YouTubeTranscriptKit.TranscriptError else {
                return XCTFail("Expected TranscriptError, got \(error)")
            }
            guard case .rateLimited(let statusCode, let url) = error else {
                return XCTFail("Expected .rateLimited, got \(error)")
            }
            XCTAssertEqual(statusCode, 200, "The CAPTCHA wall answers 200, so consumers must match the case not the status")
            XCTAssertEqual(url?.host, "www.google.com")
        }
    }

    func testTooManyRequestsIsRateLimited() throws {
        let response = try makeResponse(urlString: "https://www.youtube.com/watch?v=h0EGCnBjTVk", statusCode: 429)

        XCTAssertThrowsError(try YouTubeTranscriptKit.validate(response)) { error in
            guard case .rateLimited(let statusCode, _)? = error as? YouTubeTranscriptKit.TranscriptError else {
                return XCTFail("Expected .rateLimited, got \(error)")
            }
            XCTAssertEqual(statusCode, 429)
        }
    }

    func testNonSuccessStatusIsHTTPError() throws {
        let response = try makeResponse(urlString: "https://www.youtube.com/watch?v=h0EGCnBjTVk", statusCode: 404)

        XCTAssertThrowsError(try YouTubeTranscriptKit.validate(response)) { error in
            guard case .httpError(let statusCode, _)? = error as? YouTubeTranscriptKit.TranscriptError else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(statusCode, 404)
        }
    }

    func testSuccessfulResponsePassesValidation() throws {
        let response = try makeResponse(urlString: "https://www.youtube.com/watch?v=h0EGCnBjTVk", statusCode: 200)
        XCTAssertNoThrow(try YouTubeTranscriptKit.validate(response))
    }

    func testIsCaptchaWallMatchesGoogleSorryPaths() {
        XCTAssertTrue(YouTubeTranscriptKit.isCaptchaWall(URL(string: "https://www.google.com/sorry/index?continue=x")))
        XCTAssertTrue(YouTubeTranscriptKit.isCaptchaWall(URL(string: "https://google.com/sorry/index")))
        // Google serves the wall from country domains too
        XCTAssertTrue(YouTubeTranscriptKit.isCaptchaWall(URL(string: "https://www.google.co.uk/sorry/index")))
    }

    func testIsCaptchaWallIgnoresUnrelatedURLs() {
        XCTAssertFalse(YouTubeTranscriptKit.isCaptchaWall(URL(string: "https://www.youtube.com/watch?v=abc123")))
        XCTAssertFalse(YouTubeTranscriptKit.isCaptchaWall(URL(string: "https://www.google.com/search?q=sorry")))
        XCTAssertFalse(YouTubeTranscriptKit.isCaptchaWall(URL(string: "https://example.com/sorry/index")))
        XCTAssertFalse(YouTubeTranscriptKit.isCaptchaWall(nil))
    }

    // MARK: - Integration Tests
    // These tests hit the real YouTube API and are skipped by default.
    // Run with: YOUTUBE_INTEGRATION_TESTS=1 swift test --filter TranscriptTests/testIntegration

    func testIntegrationGetTranscript() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YOUTUBE_INTEGRATION_TESTS"] != nil,
            "Set YOUTUBE_INTEGRATION_TESTS=1 to run integration tests"
        )

        let transcript = try await YouTubeTranscriptKit.getTranscript(videoID: "ds-XlZccy7s")
        XCTAssertFalse(transcript.isEmpty, "Transcript should not be empty")
        XCTAssertGreaterThan(transcript.count, 1, "Transcript should have multiple moments")

        // Verify structure of transcript moments
        let first = transcript[0]
        XCTAssertGreaterThanOrEqual(first.start, 0.0)
        XCTAssertGreaterThan(first.duration, 0.0)
        XCTAssertFalse(first.text.isEmpty, "Transcript text should not be empty")

        // Verify moments are in chronological order
        for i in 1..<transcript.count {
            XCTAssertGreaterThanOrEqual(transcript[i].start, transcript[i - 1].start,
                                        "Transcript moments should be in chronological order")
        }
    }

    func testIntegrationGetVideoInfo() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YOUTUBE_INTEGRATION_TESTS"] != nil,
            "Set YOUTUBE_INTEGRATION_TESTS=1 to run integration tests"
        )

        let info = try await YouTubeTranscriptKit.getVideoInfo(videoID: "ds-XlZccy7s", includeTranscript: true)
        XCTAssertEqual(info.videoId, "ds-XlZccy7s")
        XCTAssertNotNil(info.title)
        XCTAssertNotNil(info.channelId)
        XCTAssertNotNil(info.channelName)
        XCTAssertNotNil(info.duration)
        XCTAssertNotNil(info.transcript)
        XCTAssertFalse(info.transcript?.isEmpty ?? true, "Transcript should not be empty")
    }

    func testIntegrationGetVideoInfoWithoutTranscript() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YOUTUBE_INTEGRATION_TESTS"] != nil,
            "Set YOUTUBE_INTEGRATION_TESTS=1 to run integration tests"
        )

        let info = try await YouTubeTranscriptKit.getVideoInfo(videoID: "ds-XlZccy7s", includeTranscript: false)
        XCTAssertEqual(info.videoId, "ds-XlZccy7s")
        XCTAssertNotNil(info.title)
        XCTAssertNil(info.transcript)
    }
}
