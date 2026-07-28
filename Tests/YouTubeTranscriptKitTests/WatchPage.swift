import Foundation
import XCTest
@testable import YouTubeTranscriptKit

/// Builds watch pages for the parser tests.
///
/// The player response is assembled from named members rather than written out per test, so a test
/// can drop or replace exactly the one it cares about and the next required field added to the model
/// only has to be filled in here. Hand-copied literals drift; the ones this replaced already had.
enum WatchPage {

    /// Ends the script statement that holds the player response.
    static let terminator = ";</script>"

    /// The statement YouTube appends after the player response for browser user agents, verbatim.
    /// Its leading semicolon is what the terminator search overshoots: `;</script>` matches only
    /// after `appendChild(meta)`, so the slice runs 169 bytes past the end of the JSON.
    static let trailingScript = ";var meta = document.createElement('meta'); meta.name = 'referrer'; "
        + "meta.content = 'origin-when-cross-origin'; "
        + "document.getElementsByTagName('head')[0].appendChild(meta)"

    /// Every member `VideoDetails` requires, named the same way the microformat ones are so a test
    /// can drop exactly the one it is about — `viewCount` being the member a members-only video
    /// really does arrive without.
    static let videoDetailsMembers: [String: String] = [
        "videoId": #""abc123""#,
        "title": #""T""#,
        "lengthSeconds": #""1""#,
        "channelId": #""UCx""#,
        "shortDescription": #""d""#,
        "viewCount": #""5""#,
        "author": #""A""#,
        "thumbnail": #"{"thumbnails":[]}"#,
        "isLiveContent": "false"
    ]

    /// Every member `PlayerMicroformat` requires, plus the two lenient ones.
    static let microformatMembers: [String: String] = [
        "title": #"{"simpleText":"Localized T"}"#,
        "description": #"{"simpleText":"Localized d"}"#,
        "lengthSeconds": #""1""#,
        "externalChannelId": #""UCx""#,
        "category": #""Education""#,
        "publishDate": #""2024-01-15T00:00:00""#,
        "uploadDate": #""2024-01-15T00:00:00""#,
        "ownerChannelName": #""A""#,
        "ownerProfileUrl": #""https://youtube.com/c/A""#
    ]

    static let captionTracks = #"{"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":"#
        + #"[{"baseUrl":"https://example.com/t","vssId":".en","languageCode":"en"}]}}}"#

    /// A `playabilityStatus`, which every watch page carries and only a blocked one puts a non-OK
    /// status in. `reason` is raw JSON, so a test can send the bare string YouTube sends today, some
    /// other shape, or nothing — the statuses that ship without a reason are the point of the `?`.
    static func playabilityStatus(_ status: String, reason: String? = nil) -> String {
        var members = ["status": "\"\(status)\""]
        if let reason {
            members["reason"] = reason
        }
        return object(members)
    }

    /// A player response that decodes cleanly, with every part overridable per test.
    ///
    /// Passing nil for `videoDetails` or `microformat` removes that object entirely, which is how a
    /// deleted video's payload arrives — not as an empty object, and not as null.
    static func playerResponse(videoDetails: [String: String]? = videoDetailsMembers,
                               microformat: [String: String]? = microformatMembers,
                               playabilityStatus: String? = nil) -> String {
        var members: [String: String] = [:]

        if let playabilityStatus {
            members["playabilityStatus"] = playabilityStatus
        }
        if let videoDetails {
            members["videoDetails"] = object(videoDetails)
        }
        if let microformat {
            members["microformat"] = "{\"playerMicroformatRenderer\":\(object(microformat))}"
        }

        return object(members)
    }

    /// Named members as a JSON object body, ordered so the same members always produce the same
    /// bytes. Values are raw JSON, never quoted here, so a member can be any shape a test needs.
    private static func object(_ members: [String: String]) -> String {
        return "{" + members
            .map { "\"\($0.key)\":\($0.value)" }
            .sorted()
            .joined(separator: ",") + "}"
    }

    /// Wraps JSON in the script block a watch page carries it in. `trailing` inserts statements
    /// between the JSON and the terminator, which is the shape that caused the parse failures.
    static func page(json: String, trailing: String = "") -> String {
        return "<html><script>var ytInitialPlayerResponse = " + json + trailing + terminator + "</html>"
    }

    /// A captured watch page from `Tests/YouTubeTranscriptKitTests/Fixtures`.
    ///
    /// Every fixture is a real fetch reduced the same way: the top-level player-response keys the
    /// parser reads are kept verbatim, and `responseContext`, `trackingParams`, `frameworkUpdates`,
    /// `messages` and `adBreakHeartbeatParams` are dropped — nothing decodes them, the first two
    /// identify the session that did the fetching, and the pages run 750KB to 1.1MB with them in.
    /// The appended `var meta` statement is always kept, because the real pages carry it and the
    /// slice has to survive it.
    private static func fixtureHTML(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name,
                                                  withExtension: "html",
                                                  subdirectory: "Fixtures"),
                                "Missing \(name).html fixture")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Captured from a real fetch with a Chrome user agent — the page that produced
    /// `videoInfoParseError` for every video in the backfill. Reduced to the members the parser
    /// reads, because the rest carried signed URLs holding the fetching machine's IP.
    static func chromeUserAgentHTML() throws -> String {
        return try fixtureHTML("chrome-ua-watch-page")
    }

    /// The real watch page of a deleted video, `s3cB-2Tm3ZM`, which reported
    /// `videoInfoParseError(keyNotFound "videoDetails")`. Its player response carries a
    /// `playabilityStatus` and nothing else the parser looks at — no `videoDetails`, no
    /// `microformat`, no `captions`.
    static func deletedVideoHTML() throws -> String {
        return try fixtureHTML("deleted-video-watch-page")
    }

    /// The real watch page of a members-only video, `smpLJS_QZg8`, which reported
    /// `videoInfoParseError(keyNotFound "viewCount", path: videoDetails)`. A non-OK status alongside
    /// otherwise complete metadata, missing only the view count YouTube does not publish for one.
    static func membersOnlyHTML() throws -> String {
        return try fixtureHTML("members-only-watch-page")
    }

    /// The player-response bytes from the Chrome user agent page, with the appended statements
    /// removed.
    ///
    /// The tail is stripped by name rather than by `leadingJSONValueBytes`, so a test that exercises
    /// that helper does not build its own baseline with it. Deriving the input from the function
    /// under test would let a broken helper quietly redefine what the test is measuring.
    static func chromeUserAgentPlayerResponse() throws -> Data {
        let html = try chromeUserAgentHTML()
        let marker = try XCTUnwrap(html.range(of: "var ytInitialPlayerResponse = "))
        let end = try XCTUnwrap(html[marker.upperBound...].range(of: terminator))
        let json = String(html[marker.upperBound..<end.lowerBound])
            .replacingOccurrences(of: trailingScript, with: "")

        let data = Data(json.utf8)
        // Independent proof the baseline really is the whole player response and nothing more.
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data),
                        "Fixture baseline is not valid JSON on its own")
        return data
    }
}
