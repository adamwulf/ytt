import XCTest
@testable import YouTubeTranscriptKit

/// YouTube appends further statements to the player-response script block for some clients, so the
/// `;</script>` terminator lands well past the end of the JSON. These cover the page level: both
/// readers of that block, against the real captured page and against synthetic ones. The boundary
/// helper itself is covered in `JSONBoundaryTests`.
final class TrailingScriptTests: XCTestCase {

    // MARK: - The real page, both readers

    func testRealChromeUserAgentPageParsesVideoInfo() async throws {
        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: WatchPage.chromeUserAgentHTML(),
                                                                   includeTranscript: false)
        XCTAssertEqual(info.videoId, "jUa2x_xpFuM")
        XCTAssertEqual(info.title, "I have a weird conspiracy theory about this bridge")
        XCTAssertEqual(info.channelName, "Tom Scott")
        XCTAssertEqual(info.category, "Education")
        XCTAssertNotNil(info.publishedAt)
    }

    /// The same blob through the caption path, which failed invisibly: it swallowed the decode error
    /// and threw `noCaptionData`, which callers treat as "this video has no captions".
    ///
    /// The assertions stop at the track list deliberately. Whether a transcript then arrives is a
    /// separate matter — YouTube returns an empty body for auto-generated (`kind=asr`) tracks fetched
    /// without authentication — and asserting on transcript text would tie this regression to a
    /// network behaviour that has nothing to do with the boundary bug.
    func testRealChromeUserAgentPageParsesCaptionTracks() throws {
        let tracks = try YouTubeTranscriptKit.extractCaptionTracks(from: WatchPage.chromeUserAgentHTML())

        XCTAssertEqual(tracks.count, 2, "Caption tracks must survive the trailing statements")
        // Manually written English first, then the auto-generated track.
        XCTAssertEqual(tracks.map(\.vssId), [".en", "a.en"])
        XCTAssertEqual(tracks.map(\.languageCode), ["en", "en"])
        XCTAssertEqual(Set(tracks.map(\.baseUrl)).count, 2, "Each track needs its own URL to fetch")
        for track in tracks {
            XCTAssertFalse(track.baseUrl.isEmpty, "Track \(track.vssId) has no baseUrl to fetch")
        }
    }

    /// The same real page without the appended statement — the shape the default CFNetwork user
    /// agent receives, which parsed before this fix and has to keep parsing after it. Deriving it
    /// from the same fixture keeps the pair honest: the only difference is the 169-byte tail.
    func testRealPageWithoutTrailingStatementsStillParses() async throws {
        let clean = try WatchPage.chromeUserAgentHTML()
            .replacingOccurrences(of: WatchPage.trailingScript, with: "")
        XCTAssertFalse(clean.contains("var meta"), "Tail was not removed, so this proves nothing")

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: clean, includeTranscript: false)
        XCTAssertEqual(info.videoId, "jUa2x_xpFuM")
        XCTAssertEqual(try YouTubeTranscriptKit.extractCaptionTracks(from: clean).count, 2)
    }

    // MARK: - Synthetic pages

    func testTrailingStatementsDoNotBreakCaptionExtraction() throws {
        let tracks = try YouTubeTranscriptKit.extractCaptionTracks(
            from: WatchPage.page(json: WatchPage.captionTracks, trailing: WatchPage.trailingScript))

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.languageCode, "en")
    }

    /// A blob that is broken rather than merely followed by junk must still surface as a parse error,
    /// not as `noVideoInfo` and not as a truncated success.
    func testGenuinelyMalformedPlayerResponseStillReportsParseError() async {
        await assertVideoInfoParseError(for: WatchPage.page(json: #"{"videoDetails":{"videoId":"abc","#))
    }

    /// A page with no marker at all carries no player response to read, and nothing to ask why.
    /// Not a schema change, and not `videoUnavailable` either: a deleted video does have the marker,
    /// and says so in its `playabilityStatus` — `PlayabilityTests` covers that.
    func testPageWithoutMarkerStillReportsNoVideoInfo() async {
        do {
            _ = try await YouTubeTranscriptKit.extractVideoInfo(from: "<html></html>",
                                                                includeTranscript: false)
            XCTFail("Expected noVideoInfo")
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            guard case .noVideoInfo = error else {
                return XCTFail("Expected .noVideoInfo, got \(error)")
            }
        } catch {
            XCTFail("Expected TranscriptError, got \(error)")
        }
    }

    /// The known limit of slicing at the first terminator: a literal `;</script>` inside the JSON
    /// cuts the slice short, and no amount of trimming recovers the rest. It does not happen because
    /// YouTube escapes forward slashes in these blobs, so the sequence arrives as `<\/script>` — the
    /// case just below proves that escaped form parses. What matters is that the unescaped form fails
    /// loudly instead of yielding a half-decoded video.
    func testLiteralTerminatorInsideJSONFailsLoudly() async {
        let json = WatchPage.playerResponse(microformat: {
            var members = WatchPage.microformatMembers
            members["category"] = #""Education;</script>tail""#
            return members
        }())

        await assertVideoInfoParseError(for: WatchPage.page(json: json))
    }

    /// The escaped form of the exact sequence above, semicolon included — anything without the
    /// leading `;` would parse whether or not slashes were escaped, and so would prove nothing.
    /// This is what YouTube actually emits, and it has to keep working.
    func testEscapedTerminatorInsideJSONParsesNormally() async throws {
        let json = WatchPage.playerResponse(microformat: {
            var members = WatchPage.microformatMembers
            members["category"] = #""Education;<\/script>tail""#
            return members
        }())

        let info = try await YouTubeTranscriptKit.extractVideoInfo(
            from: WatchPage.page(json: json, trailing: WatchPage.trailingScript), includeTranscript: false)
        XCTAssertEqual(info.category, "Education;</script>tail")
    }

    /// The loop must keep walking later matches: the first block on a page is not always the one that
    /// decodes. An early exit here would regress any page that carries a decoy block first.
    func testLaterMarkerMatchIsStillTriedAfterAnEarlierOneFails() async throws {
        let page = WatchPage.page(json: #"{"videoDetails":{"videoId":"nope"}}"#,
                                  trailing: WatchPage.trailingScript)
            + WatchPage.page(json: WatchPage.playerResponse(), trailing: WatchPage.trailingScript)

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
        XCTAssertEqual(info.videoId, "abc123")
    }

    /// The caption path has no error to report, so an unusable blob has to leave it empty rather than
    /// half-populated. Nothing else pins that, and the code comment there admits it is invisible.
    func testCaptionPathDegradesToNoCaptionDataOnUnusableBlob() {
        let page = WatchPage.page(json: #"{"captions":{"playerCaptionsTracklistRenderer":{"#)

        do {
            let tracks = try YouTubeTranscriptKit.extractCaptionTracks(from: page)
            XCTFail("Expected noCaptionData, got \(tracks.count) tracks")
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            guard case .noCaptionData = error else {
                return XCTFail("Expected .noCaptionData, got \(error)")
            }
        } catch {
            XCTFail("Expected TranscriptError, got \(error)")
        }
    }

    // MARK: - Helpers

    private func assertVideoInfoParseError(for page: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) async {
        do {
            let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
            XCTFail("Expected videoInfoParseError, got \(info.videoId ?? "nil")", file: file, line: line)
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            guard case .videoInfoParseError = error else {
                return XCTFail("Expected .videoInfoParseError, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected TranscriptError, got \(error)", file: file, line: line)
        }
    }
}
