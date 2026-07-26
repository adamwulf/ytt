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

    static let videoDetails = #"{"videoId":"abc123","title":"T","lengthSeconds":"1","#
        + #""channelId":"UCx","shortDescription":"d","viewCount":"5","author":"A","#
        + #""thumbnail":{"thumbnails":[]},"isLiveContent":false}"#

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

    /// A player response that decodes cleanly, with `microformat` overridable per test.
    static func playerResponse(microformat: [String: String] = microformatMembers) -> String {
        let members = microformat
            .map { "\"\($0.key)\":\($0.value)" }
            .sorted()
            .joined(separator: ",")

        return "{\"videoDetails\":\(videoDetails),"
            + "\"microformat\":{\"playerMicroformatRenderer\":{\(members)}}}"
    }

    /// Wraps JSON in the script block a watch page carries it in. `trailing` inserts statements
    /// between the JSON and the terminator, which is the shape that caused the parse failures.
    static func page(json: String, trailing: String = "") -> String {
        return "<html><script>var ytInitialPlayerResponse = " + json + trailing + terminator + "</html>"
    }

    /// Captured from a real fetch with a Chrome user agent — the page that produced
    /// `videoInfoParseError` for every video in the backfill. Reduced to the members the parser
    /// reads, because the rest carried signed URLs holding the fetching machine's IP.
    static func chromeUserAgentHTML() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "chrome-ua-watch-page",
                                                  withExtension: "html",
                                                  subdirectory: "Fixtures"),
                                "Missing chrome-ua-watch-page.html fixture")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The player-response bytes from that page, with the appended statements removed.
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
