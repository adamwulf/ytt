import XCTest
@testable import YouTubeTranscriptKit

/// Two real pages threw `videoInfoParseError`, whose whole meaning is "YouTube changed their schema".
/// Neither had. A deleted video's player response simply has no `videoDetails`, and a members-only
/// video's has no `viewCount`, because YouTube publishes no view count for one. The first now reports
/// `videoUnavailable`, the second decodes like any other video, and the schema-change signal is left
/// meaning only what it says.
final class PlayabilityTests: XCTestCase {

    // MARK: - The real pages

    /// `s3cB-2Tm3ZM`. Reported `keyNotFound "videoDetails"` — technically true, diagnostically the
    /// exact opposite of the truth, since a deleted video is what the old comment said the error did
    /// not mean.
    func testRealDeletedVideoPageReportsVideoUnavailable() async throws {
        let page = try WatchPage.deletedVideoHTML()

        do {
            let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
            XCTFail("Expected videoUnavailable, got a VideoInfo for \(info.videoId ?? "nil")")
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            guard case .videoUnavailable(let status, let reason) = error else {
                return XCTFail("Expected .videoUnavailable, got \(error)")
            }
            XCTAssertEqual(status, "ERROR", "hunch classifies on the status code, not the prose")
            XCTAssertEqual(reason, "Video unavailable")
        } catch {
            XCTFail("Expected TranscriptError, got \(error)")
        }
    }

    /// `smpLJS_QZg8`. Reported `keyNotFound "viewCount", path: videoDetails` and threw away the title,
    /// description, channel, duration and thumbnails that were all sitting right there.
    func testRealMembersOnlyPageReturnsCompleteVideoInfo() async throws {
        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: WatchPage.membersOnlyHTML(),
                                                                  includeTranscript: false)

        XCTAssertEqual(info.videoId, "smpLJS_QZg8")
        XCTAssertEqual(info.title, "Space Marines, Space Fleets, & Non-Space Dungeons")
        XCTAssertEqual(info.channelId, "UCwX8RD5ivBjTm1QHIv7fm_Q")
        XCTAssertEqual(info.channelName, "Nookrium")
        XCTAssertEqual(info.duration, 14137)
        XCTAssertEqual(info.category, "Gaming")
        XCTAssertEqual(info.isLive, false)
        XCTAssertEqual(info.thumbnails?.count, 5)
        XCTAssertNotNil(info.publishedAt)
        XCTAssertNotNil(info.uploadedAt)
        XCTAssertEqual(info.videoURL?.absoluteString, "https://www.youtube.com/watch?v=smpLJS_QZg8")
        XCTAssertEqual(info.channelURL?.absoluteString,
                       "https://www.youtube.com/channel/UCwX8RD5ivBjTm1QHIv7fm_Q")
        XCTAssertTrue(info.description?.hasPrefix("Today's stream is sponsored by") == true,
                      "Description came back as \(info.description ?? "nil")")

        // The one field that really is absent, and the only thing losing it costs.
        XCTAssertNil(info.viewCount, "YouTube publishes no view count for a members-only video")
    }

    /// Every non-OK status, not just the deleted video's `ERROR`. The condition is `!= "OK"`, and
    /// nothing pinned that generality: narrowing it to `== "ERROR"` passed the whole suite while
    /// sending private and blocked videos back to `videoInfoParseError` — the bug this exists to fix.
    ///
    /// `LOGIN_REQUIRED` is listed because the code does report it, not because that is known to be
    /// the right answer for every page carrying it — see the note on the `videoUnavailable` case.
    func testEveryNonOKStatusReportsVideoUnavailable() async {
        for expected in ["ERROR", "UNPLAYABLE", "LOGIN_REQUIRED", "AGE_VERIFICATION_REQUIRED"] {
            let page = WatchPage.page(json: WatchPage.playerResponse(
                videoDetails: nil, microformat: nil,
                playabilityStatus: WatchPage.playabilityStatus(expected)))

            do {
                _ = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
                XCTFail("Expected videoUnavailable for \(expected)")
            } catch let error as YouTubeTranscriptKit.TranscriptError {
                guard case .videoUnavailable(let status, _) = error else {
                    return XCTFail("Expected .videoUnavailable for \(expected), got \(error)")
                }
                XCTAssertEqual(status, expected)
            } catch {
                XCTFail("Expected TranscriptError for \(expected), got \(error)")
            }
        }
    }

    // MARK: - The check has to come after the decode, not before it

    /// The ordering this whole change turns on. A members-only video reports a non-OK status *and*
    /// carries everything worth keeping, so a status check placed ahead of the decode loop would
    /// throw away exactly the case the fix exists to rescue.
    func testNonOKStatusWithCompleteDetailsStillReturnsVideoInfo() async throws {
        let page = WatchPage.page(json: WatchPage.playerResponse(
            playabilityStatus: WatchPage.playabilityStatus("UNPLAYABLE", reason: #""Join this channel""#)))

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
        XCTAssertEqual(info.videoId, "abc123")
        XCTAssertEqual(info.title, "T")
        XCTAssertEqual(info.duration, 1)
    }

    /// The same ordering across blobs: a first blob that cannot decode must not have its status
    /// reported while a later blob still holds a whole video.
    func testNonOKStatusOnAnEarlierBlobDoesNotPreemptALaterGoodOne() async throws {
        let blocked = WatchPage.playerResponse(videoDetails: nil, microformat: nil,
                                               playabilityStatus: WatchPage.playabilityStatus("ERROR"))
        let page = WatchPage.page(json: blocked) + WatchPage.page(json: WatchPage.playerResponse())

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
        XCTAssertEqual(info.videoId, "abc123")
    }

    // MARK: - videoInfoParseError keeps meaning a schema change

    /// A payload YouTube says is fine, with the key the parser needs missing, is the schema change
    /// `videoInfoParseError` is named for. `videoUnavailable` must not swallow it.
    func testOKStatusWithoutVideoDetailsIsStillAParseError() async {
        let page = WatchPage.page(json: WatchPage.playerResponse(
            videoDetails: nil, playabilityStatus: WatchPage.playabilityStatus("OK")))

        await assertVideoInfoParseError(for: page)
    }

    /// A status the parser cannot read is no status at all, so the payload is reported as what it
    /// otherwise is: unparseable.
    func testUnreadableStatusFallsBackToParseError() async {
        // `status` renamed — the shape a schema change to playabilityStatus itself would take.
        let page = WatchPage.page(json: WatchPage.playerResponse(
            videoDetails: nil, playabilityStatus: #"{"playabilityState":"ERROR"}"#))

        await assertVideoInfoParseError(for: page)
    }

    // MARK: - viewCount

    /// The members-only case reduced to the one member that caused it, so the next required field
    /// added to `VideoDetails` cannot quietly re-break it.
    func testAbsentViewCountCostsOnlyTheViewCount() async throws {
        var members = WatchPage.videoDetailsMembers
        members.removeValue(forKey: "viewCount")
        let page = WatchPage.page(json: WatchPage.playerResponse(videoDetails: members))

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
        XCTAssertNil(info.viewCount)
        XCTAssertEqual(info.videoId, "abc123")
        XCTAssertEqual(info.title, "T")
        XCTAssertEqual(info.channelId, "UCx")
        XCTAssertEqual(info.channelName, "A")
        XCTAssertEqual(info.description, "d")
        XCTAssertEqual(info.duration, 1)
        XCTAssertEqual(info.category, "Education")
    }

    /// Present and numeric still parses, and present but not a number still degrades rather than
    /// throwing — the behaviour `Int(_:)` gave before the field became optional.
    func testViewCountShapes() async throws {
        let cases: [(String?, Int?)] = [
            (#""1000""#, 1000),
            (#""""#, nil),
            (#""1,000""#, nil),   // never seen, but a thousands separator would arrive as this
            ("null", nil),
            (nil, nil)
        ]

        for (raw, expected) in cases {
            var members = WatchPage.videoDetailsMembers
            members["viewCount"] = raw
            let page = WatchPage.page(json: WatchPage.playerResponse(videoDetails: members))

            let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
            XCTAssertEqual(info.viewCount, expected, "Failed for viewCount \(raw ?? "absent")")
            XCTAssertEqual(info.videoId, "abc123", "Failed for viewCount \(raw ?? "absent")")
        }
    }

    // MARK: - What the error carries

    /// hunch records `videoUnavailable` on disk and never fetches that video again, which only works
    /// if the error is not mistaken for something a retry could fix.
    func testVideoUnavailableIsNotATransientFailure() {
        let error = YouTubeTranscriptKit.TranscriptError.videoUnavailable(status: "ERROR",
                                                                         reason: "Video unavailable")
        XCTAssertFalse(YouTubeTranscriptKit.isTransientFetchFailure(error),
                       "A deleted video is still deleted next run; retrying it never drains the queue")
    }

    func testPlayabilityStatusReadsEveryReasonShape() throws {
        let shapes: [(String, String?)] = [
            (#"{"status":"ERROR","reason":"Video unavailable"}"#, "Video unavailable"),
            (#"{"status":"ERROR","reason":{"simpleText":"Video unavailable"}}"#, "Video unavailable"),
            (#"{"status":"ERROR","reason":{"runs":[{"text":"Video "},{"text":"unavailable"}]}}"#,
             "Video unavailable"),
            (#"{"status":"ERROR","reason":{"unknownShape":true}}"#, nil),
            (#"{"status":"ERROR"}"#, nil),
            (#"{"status":"ERROR","reason":null}"#, nil)
        ]

        for (json, expected) in shapes {
            let status = try JSONDecoder().decode(PlayabilityStatus.self, from: Data(json.utf8))
            XCTAssertEqual(status.status, "ERROR", "Failed for \(json)")
            XCTAssertEqual(status.reason, expected, "Failed for \(json)")
        }
    }

    /// `status` is the one member that is genuinely required, because it is the only thing a caller
    /// can act on. Without it the decode has to fail so the parse error survives instead.
    func testPlayabilityStatusWithoutAStatusFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(PlayabilityStatus.self,
                                                      from: Data(#"{"reason":"Video unavailable"}"#.utf8)))
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
