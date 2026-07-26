import XCTest
@testable import YouTubeTranscriptKit

/// YouTube renders text as either `{"runs":[{"text":"..."}]}` or `{"simpleText":"..."}` and moves
/// fields between the two over time. The microformat title and description were modelled as required
/// `runs` containers, so the day they became `simpleText` every video stopped decoding — even though
/// nothing reads either field. These pin the leniency that keeps a cosmetic change from doing that
/// again, and the strictness that must survive alongside it.
final class MicroformatTextTests: XCTestCase {

    private static func page(title: String, description: String) -> String {
        let json = #"{"videoDetails":{"videoId":"abc123","title":"T","lengthSeconds":"1","#
            + #""channelId":"UCx","shortDescription":"d","viewCount":"5","author":"A","#
            + #""thumbnail":{"thumbnails":[]},"isLiveContent":false},"#
            + #""microformat":{"playerMicroformatRenderer":{"title":\#(title),"#
            + #""description":\#(description),"#
            + #""lengthSeconds":"1","externalChannelId":"UCx","category":"Education","#
            + #""publishDate":"2024-01-15T00:00:00","uploadDate":"2024-01-15T00:00:00","#
            + #""ownerChannelName":"A","ownerProfileUrl":"https://youtube.com/c/A"}}}"#

        return "<html><script>var ytInitialPlayerResponse = " + json
            + String(UnicodeScalar(59)) + "</script></html>"
    }

    func testMicroformatTextAcceptsEitherShape() async throws {
        let shapes = [
            (#"{"simpleText":"Hello"}"#, #"{"simpleText":"World"}"#),        // what YouTube sends today
            (#"{"runs":[{"text":"He"},{"text":"llo"}]}"#, #"{"runs":[]}"#),  // the shape it sent before
            (#"{"unknownShape":true}"#, #"{"unknownShape":true}"#),          // whatever comes next
            ("null", "null"),
            (#""a bare string""#, "42")
        ]

        for (title, description) in shapes {
            let info = try await YouTubeTranscriptKit.extractVideoInfo(
                from: Self.page(title: title, description: description), includeTranscript: false)

            // What the caller receives comes from videoDetails regardless of the microformat shape.
            XCTAssertEqual(info.videoId, "abc123", "Failed for microformat title \(title)")
            XCTAssertEqual(info.title, "T", "Failed for microformat title \(title)")
            XCTAssertEqual(info.category, "Education")
        }
    }

    func testRenderedTextReadsBothShapes() throws {
        let runs = try JSONDecoder().decode(RenderedText.self,
                                            from: Data(#"{"runs":[{"text":"He"},{"text":"llo"}]}"#.utf8))
        XCTAssertEqual(runs.text, "Hello")

        let simple = try JSONDecoder().decode(RenderedText.self,
                                              from: Data(#"{"simpleText":"Hello"}"#.utf8))
        XCTAssertEqual(simple.text, "Hello")

        let unknown = try JSONDecoder().decode(RenderedText.self, from: Data(#"{"other":1}"#.utf8))
        XCTAssertNil(unknown.text)
    }

    /// The leniency is scoped to fields nothing reads. A field the parser actually depends on must
    /// still fail loudly, or a real schema change would reach callers as a plausible-looking blank.
    func testFieldsThatAreActuallyReadStayStrict() async {
        let json = #"{"videoDetails":{"videoId":"abc123","title":"T","lengthSeconds":"1","#
            + #""channelId":"UCx","shortDescription":"d","viewCount":"5","author":"A","#
            + #""thumbnail":{"thumbnails":[]},"isLiveContent":false},"#
            + #""microformat":{"playerMicroformatRenderer":{"title":{"simpleText":"x"},"#
            + #""lengthSeconds":"1","externalChannelId":"UCx","#
            // category, publishDate and uploadDate are all read by extractVideoInfo; category is gone
            + #""publishDate":"2024-01-15T00:00:00","uploadDate":"2024-01-15T00:00:00","#
            + #""ownerChannelName":"A","ownerProfileUrl":"https://youtube.com/c/A"}}}"#
        let page = "<html><script>var ytInitialPlayerResponse = " + json
            + String(UnicodeScalar(59)) + "</script></html>"

        do {
            _ = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
            XCTFail("A missing category must not decode to a silently empty VideoInfo")
        } catch let error as YouTubeTranscriptKit.TranscriptError {
            guard case .videoInfoParseError = error else {
                return XCTFail("Expected .videoInfoParseError, got \(error)")
            }
        } catch {
            XCTFail("Expected TranscriptError, got \(error)")
        }
    }
}
