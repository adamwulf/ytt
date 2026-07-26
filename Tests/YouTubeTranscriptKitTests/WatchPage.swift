import Foundation

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
}
