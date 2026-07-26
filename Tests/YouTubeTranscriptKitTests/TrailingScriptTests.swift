import XCTest
@testable import YouTubeTranscriptKit

/// YouTube appends further statements to the player-response script block for some clients, so the
/// `;</script>` terminator lands well past the end of the JSON. Everything here pins the behaviour
/// that lets the blob decode anyway — and, just as importantly, the behaviour that keeps genuinely
/// broken JSON loud instead of silently truncating it into a half-object.
final class TrailingScriptTests: XCTestCase {

    // The verbatim statement YouTube appends after the player response for browser user agents.
    // The leading semicolon is what the old terminator search overshot: `;</script>` matched only
    // after `appendChild(meta)`, handing the decoder 169 extra bytes.
    private static let trailingScript = ";var meta = document.createElement('meta'); meta.name = 'referrer'; "
        + "meta.content = 'origin-when-cross-origin'; "
        + "document.getElementsByTagName('head')[0].appendChild(meta)"

    private static func page(json: String, trailing: String = "") -> String {
        return "<html><script>var ytInitialPlayerResponse = " + json + trailing
            + String(UnicodeScalar(59)) + "</script></html>"
    }

    // MARK: - The parser finds the boundary

    func testLeadingObjectRecoversFromTrailingStatements() {
        let json = #"{"a":1}"#
        let data = Data((json + Self.trailingScript).utf8)

        guard let recovered = YouTubeTranscriptKit.leadingJSONObject(in: data) else {
            return XCTFail("Expected recovery from a blob with trailing statements")
        }
        XCTAssertEqual(String(data: recovered, encoding: .utf8), json)
    }

    func testLeadingObjectLeavesCleanJSONUntouched() {
        let data = Data(#"{"a":{"b":[1,2,3]}}"#.utf8)
        XCTAssertEqual(YouTubeTranscriptKit.leadingJSONObject(in: data), data)
    }

    /// The cases a hand-rolled brace counter gets wrong. The real parser owns escape handling here,
    /// so there is no bespoke state machine to drift out of spec.
    func testLeadingObjectHandlesBracesAndTerminatorsInsideStrings() {
        let cases = [
            #"{"a":"}"}"#,                      // brace in string
            #"{"a":"\"}"}"#,                    // escaped quote then brace
            #"{"a":"\\"}"#,                     // trailing backslash
            #"{"a":"</script>"}"#,              // script tag in string
            #"{"a":";</script>"}"#,             // full terminator in string
            #"{"a":{"b":{"c":"}"}},"d":[1,"{"]}"#
        ]

        for json in cases {
            let data = Data((json + Self.trailingScript).utf8)
            let recovered = YouTubeTranscriptKit.leadingJSONObject(in: data)
            XCTAssertEqual(String(data: recovered ?? Data(), encoding: .utf8), json,
                           "Failed to recover \(json) byte-exactly")
        }
    }

    // MARK: - Broken JSON must stay broken

    /// The revalidation guard. Without it a real schema change would yield a truncated object, which
    /// is far worse than an error: callers cannot tell a half-parsed response from a complete one.
    func testLeadingObjectRefusesMalformedJSON() {
        XCTAssertNil(YouTubeTranscriptKit.leadingJSONObject(in: Data(#"{"a":1,"b":}"#.utf8)),
                     "Malformed JSON must not yield a truncated object")
        XCTAssertNil(YouTubeTranscriptKit.leadingJSONObject(in: Data(#"{"a":{"b":1}"#.utf8)),
                     "Unterminated JSON must not yield a truncated object")
        XCTAssertNil(YouTubeTranscriptKit.leadingJSONObject(in: Data("".utf8)))
    }

    /// Pins the Foundation behaviour the recovery leans on. If `NSJSONSerializationErrorIndex` ever
    /// stops being reported, or stops pointing at the byte after the top-level value, this fails
    /// loudly rather than the fix quietly degrading back into the original bug.
    func testFoundationStillReportsTheErrorIndexRecoveryDependsOn() {
        let json = #"{"a":"}"}"#
        let data = Data((json + Self.trailingScript).utf8)

        do {
            _ = try JSONSerialization.jsonObject(with: data)
            XCTFail("Expected trailing data to be rejected")
        } catch let error as NSError {
            let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int
            XCTAssertEqual(index, json.utf8.count,
                           "Recovery depends on this index pointing just past the top-level value")
        }
    }

    // MARK: - Both call sites, against the real page

    private func chromeUserAgentPage() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "chrome-ua-watch-page",
                                                  withExtension: "html",
                                                  subdirectory: "Fixtures"),
                                "Missing chrome-ua-watch-page.html fixture")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Captured from a real fetch with a Chrome user agent — the page that produced
    /// `videoInfoParseError` for every video in the backfill.
    func testRealChromeUserAgentPageParsesVideoInfo() async throws {
        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: chromeUserAgentPage(),
                                                                   includeTranscript: false)
        XCTAssertEqual(info.videoId, "jUa2x_xpFuM")
        XCTAssertEqual(info.title, "I have a weird conspiracy theory about this bridge")
        XCTAssertEqual(info.channelName, "Tom Scott")
        XCTAssertEqual(info.category, "Education")
        XCTAssertNotNil(info.publishedAt)
    }

    /// The same blob decoded through the caption path, which failed invisibly: it swallowed the
    /// decode error and threw `noCaptionData`, which callers treat as "this video has no captions".
    ///
    /// The assertion stops at the track list on purpose. Whether the transcript itself arrives is a
    /// separate matter — YouTube now returns an empty body for auto-generated (`kind=asr`) tracks
    /// requested without authentication — and asserting on transcript text would tie this regression
    /// to a network behaviour that has nothing to do with the boundary bug.
    func testRealChromeUserAgentPageParsesCaptionTracks() throws {
        let tracks = try YouTubeTranscriptKit.extractCaptionTracks(from: chromeUserAgentPage())

        XCTAssertEqual(tracks.count, 2, "Caption tracks must survive the trailing statements")
        XCTAssertEqual(tracks.first?.languageCode, "en")
        // English before the auto-generated 'a.en' track, and every track needs a usable URL.
        XCTAssertEqual(tracks.map(\.vssId), [".en", "a.en"])
        for track in tracks {
            XCTAssertFalse(track.baseUrl.isEmpty, "Track \(track.vssId) has no baseUrl to fetch")
        }
    }

    /// The same real page without the appended statement — the shape the default CFNetwork user
    /// agent receives, which parsed before this fix and has to keep parsing after it. Deriving it
    /// from the same fixture keeps the two cases honest: the only difference is the 169-byte tail.
    func testRealPageWithoutTrailingStatementsStillParses() async throws {
        let clean = try chromeUserAgentPage()
            .replacingOccurrences(of: Self.trailingScript, with: "")
        XCTAssertFalse(clean.contains("var meta"), "Tail was not removed, so this proves nothing")

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: clean, includeTranscript: false)
        XCTAssertEqual(info.videoId, "jUa2x_xpFuM")
        XCTAssertEqual(try YouTubeTranscriptKit.extractCaptionTracks(from: clean).count, 2)
    }

    func testTrailingStatementsDoNotBreakCaptionExtraction() throws {
        let json = #"{"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":"#
            + #"[{"baseUrl":"https://example.com/t","vssId":".en","languageCode":"en"}]}}}"#

        let tracks = try YouTubeTranscriptKit.extractCaptionTracks(
            from: Self.page(json: json, trailing: Self.trailingScript))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.languageCode, "en")
    }

    // MARK: - Error taxonomy survives

    /// A blob that is broken rather than merely followed by junk must still surface as a parse
    /// error, not as `noVideoInfo` and not as a truncated success.
    func testGenuinelyMalformedPlayerResponseStillReportsParseError() async {
        let page = Self.page(json: #"{"videoDetails":{"videoId":"abc","#)

        do {
            _ = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
            XCTFail("Expected videoInfoParseError")
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            guard case .videoInfoParseError = error else {
                return XCTFail("Expected .videoInfoParseError, got \(error)")
            }
        } catch {
            XCTFail("Expected TranscriptError, got \(error)")
        }
    }

    /// A page with no marker at all is a missing/private/deleted video, not a schema change.
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

    /// The loop must keep walking later matches: the first block on a real page is not always the
    /// one that decodes. A terminating loop is the other half of this — an early `break` here would
    /// regress pages that carry a decoy block first.
    func testLaterMarkerMatchIsStillTriedAfterAnEarlierOneFails() async throws {
        let decoy = #"{"videoDetails":{"videoId":"nope"}}"#
        let real = #"{"videoDetails":{"videoId":"abc123","title":"T","lengthSeconds":"1","#
            + #""channelId":"UCx","shortDescription":"d","viewCount":"5","author":"A","#
            + #""thumbnail":{"thumbnails":[]},"isLiveContent":false},"#
            + #""microformat":{"playerMicroformatRenderer":{"title":{"runs":[{"text":"T"}]},"#
            + #""lengthSeconds":"1","externalChannelId":"UCx","category":"Education","#
            + #""publishDate":"2024-01-15T00:00:00","uploadDate":"2024-01-15T00:00:00","#
            + #""ownerChannelName":"A","ownerProfileUrl":"https://youtube.com/c/A"}}}"#

        let page = Self.page(json: decoy, trailing: Self.trailingScript)
            + Self.page(json: real, trailing: Self.trailingScript)

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
        XCTAssertEqual(info.videoId, "abc123")
    }
}
