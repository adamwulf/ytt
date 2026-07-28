import XCTest
@testable import YouTubeTranscriptKit

/// YouTube renders text as either `{"runs":[{"text":"..."}]}` or `{"simpleText":"..."}` and moves
/// fields between the two over time. The microformat title and description were modelled as required
/// `runs` containers, so the day they became `simpleText` every video stopped decoding — even though
/// nothing reads either field. These pin the leniency that stops a cosmetic change doing that again,
/// and the strictness that has to survive alongside it.
final class MicroformatTextTests: XCTestCase {

    private static func page(title: String?, description: String?) -> String {
        var members = WatchPage.microformatMembers
        // A nil override removes the member, which is not the same as sending null and is the case
        // that the optional type — rather than the lenient decoder — is what survives.
        members["title"] = title
        members["description"] = description
        return WatchPage.page(json: WatchPage.playerResponse(microformat: members))
    }

    func testMicroformatTextAcceptsEitherShape() async throws {
        let shapes: [(String?, String?)] = [
            (#"{"simpleText":"Hello"}"#, #"{"simpleText":"World"}"#),        // what YouTube sends today
            (#"{"runs":[{"text":"He"},{"text":"llo"}]}"#, #"{"runs":[]}"#),  // the shape it sent before
            (#"{"unknownShape":true}"#, #"{"unknownShape":true}"#),          // whatever comes next
            ("null", "null"),
            (#""a bare string""#, "42"),
            (nil, nil)                                                       // the key removed entirely
        ]

        for (title, description) in shapes {
            let info = try await YouTubeTranscriptKit.extractVideoInfo(
                from: Self.page(title: title, description: description), includeTranscript: false)

            // What the caller receives comes from videoDetails regardless of the microformat shape.
            XCTAssertEqual(info.videoId, "abc123", "Failed for microformat title \(title ?? "absent")")
            XCTAssertEqual(info.title, "T", "Failed for microformat title \(title ?? "absent")")
            XCTAssertEqual(info.category, "Education")
        }
    }

    /// Guards the `?` specifically. Leniency inside the decoder does not cover an absent key — an
    /// optional does — and with the field non-optional this is the case that fails.
    func testAbsentMicroformatTitleDecodes() async throws {
        var members = WatchPage.microformatMembers
        members.removeValue(forKey: "title")
        members.removeValue(forKey: "description")
        let page = WatchPage.page(json: WatchPage.playerResponse(microformat: members))

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
        XCTAssertEqual(info.videoId, "abc123")
    }

    func testRenderedTextReadsBothShapes() throws {
        let runs = try JSONDecoder().decode(RenderedText.self,
                                            from: Data(#"{"runs":[{"text":"He"},{"text":"llo"}]}"#.utf8))
        XCTAssertEqual(runs.text, "Hello")

        let simple = try JSONDecoder().decode(RenderedText.self,
                                              from: Data(#"{"simpleText":"Hello"}"#.utf8))
        XCTAssertEqual(simple.text, "Hello")

        // Present and well formed but carrying nothing is "", not nil — nil means "shape not known".
        let empty = try JSONDecoder().decode(RenderedText.self, from: Data(#"{"runs":[]}"#.utf8))
        XCTAssertEqual(empty.text, "")

        let unknown = try JSONDecoder().decode(RenderedText.self, from: Data(#"{"other":1}"#.utf8))
        XCTAssertNil(unknown.text)
    }

    /// No microformat member that nothing reads may fail a decode — that is the whole point of the
    /// branch, and leaving any of them required would have been the next outage of the same class.
    /// Note `lengthSeconds` belongs here, not in the strict list: the duration callers get is parsed
    /// from `videoDetails.lengthSeconds`, and the microformat copy is never touched.
    func testUnreadMicroformatMembersCanAllDisappear() async throws {
        var members = WatchPage.microformatMembers
        for unread in ["title", "description", "lengthSeconds", "externalChannelId",
                       "ownerChannelName", "ownerProfileUrl"] {
            members.removeValue(forKey: unread)
        }
        let page = WatchPage.page(json: WatchPage.playerResponse(microformat: members))

        let info = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
        XCTAssertEqual(info.videoId, "abc123")
        XCTAssertEqual(info.duration, 1, "Duration must still come from videoDetails")
        XCTAssertEqual(info.category, "Education")
    }

    /// The leniency is scoped to fields nothing reads. These three the parser depends on must still
    /// fail loudly, or a real schema change reaches callers as a plausible-looking blank.
    ///
    /// Scoped to the microformat on purpose. "Read implies required" is not the rule across the whole
    /// model — `liveBroadcastDetails` and `VideoDetails.viewCount` are both read and both optional,
    /// because their absence is meaningful rather than suspicious. `Model+Internal.swift` states the
    /// rule these three are an instance of.
    func testReadMicroformatFieldsStayStrict() async {
        for required in ["category", "publishDate", "uploadDate"] {
            var members = WatchPage.microformatMembers
            members.removeValue(forKey: required)
            let page = WatchPage.page(json: WatchPage.playerResponse(microformat: members))

            do {
                _ = try await YouTubeTranscriptKit.extractVideoInfo(from: page, includeTranscript: false)
                XCTFail("A missing \(required) must not decode to a silently incomplete VideoInfo")
            } catch let error as YouTubeTranscriptKit.TranscriptError {
                guard case .videoInfoParseError = error else {
                    return XCTFail("Expected .videoInfoParseError for \(required), got \(error)")
                }
            } catch {
                XCTFail("Expected TranscriptError for \(required), got \(error)")
            }
        }
    }
}
