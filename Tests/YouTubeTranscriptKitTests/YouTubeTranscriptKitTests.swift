import XCTest
@testable import YouTubeTranscriptKit

final class YouTubeTranscriptKitTests: XCTestCase {

    // MARK: - Activity Parsing

    func testParseActivityWithNoLink() async throws {
        let html = """
        <html><body>
        <div class="outer-cell mdl-cell mdl-cell--12-col mdl-shadow--2dp">
        <div class="mdl-grid">
        <div class="header-cell mdl-cell mdl-cell--12-col">
        <p class="mdl-typography--title">YouTube<br></p>
        </div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">Used Shorts creation tools<br>Apr 12, 2026, 11:00:07 AM CDT<br></div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1 mdl-typography--text-right"></div>
        </div>
        </div>
        </body></html>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_activity_no_link.html")
        try html.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let activities = try await YouTubeTranscriptKit.getActivity(fileURL: tempURL)
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].action, .usedShortsCreationTools)
        if case .none = activities[0].link {
            // expected
        } else {
            XCTFail("Expected .none link, got \(activities[0].link)")
        }
        XCTAssertNil(activities[0].link.url)
    }

    func testParseActivityWithVideoLink() async throws {
        let html = """
        <html><body>
        <div class="outer-cell mdl-cell mdl-cell--12-col mdl-shadow--2dp">
        <div class="mdl-grid">
        <div class="header-cell mdl-cell mdl-cell--12-col">
        <p class="mdl-typography--title">YouTube<br></p>
        </div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">Watched <a href="https://www.youtube.com/watch?v=abc123">Test Video</a><br>Apr 12, 2026, 10:00:00 AM CDT<br></div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1 mdl-typography--text-right"></div>
        </div>
        </div>
        </body></html>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_activity_video.html")
        try html.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let activities = try await YouTubeTranscriptKit.getActivity(fileURL: tempURL)
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].action, .watched)
        if case .video(let id, let title) = activities[0].link {
            XCTAssertEqual(id, "abc123")
            XCTAssertEqual(title, "Test Video")
        } else {
            XCTFail("Expected .video link, got \(activities[0].link)")
        }
        XCTAssertNotNil(activities[0].link.url)
    }

    func testParseUnavailablePostReturnsNil() async throws {
        let html = """
        <html><body>
        <div class="outer-cell mdl-cell mdl-cell--12-col mdl-shadow--2dp">
        <div class="mdl-grid">
        <div class="header-cell mdl-cell mdl-cell--12-col">
        <p class="mdl-typography--title">YouTube<br></p>
        </div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">Viewed a post that is no longer available<br>Apr 12, 2026, 9:00:00 AM CDT<br></div>
        <div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1 mdl-typography--text-right"></div>
        </div>
        </div>
        </body></html>
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_activity_unavailable.html")
        try html.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let activities = try await YouTubeTranscriptKit.getActivity(fileURL: tempURL)
        XCTAssertEqual(activities.count, 0)
    }

    func testParseSharedVideoActivity() async throws {
        // Use Unicode scalar to build HTML entities without literal semicolons in source
        let sc = String(UnicodeScalar(59))
        let amp = "&amp\(sc)"
        let emsp = "&emsp\(sc)"
        let videoURL = "https://youtube.com/watch?v=91AJ0cpgLlQ\(amp)si=YuAnMOTLcrxcDecZ"
        let html = "<html><body>"
            + "<div class=\"outer-cell mdl-cell mdl-cell--12-col mdl-shadow--2dp\">"
            + "<div class=\"mdl-grid\">"
            + "<div class=\"header-cell mdl-cell mdl-cell--12-col\">"
            + "<p class=\"mdl-typography--title\">YouTube<br></p></div>"
            + "<div class=\"content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1\">"
            + "<a href=\"\(videoURL)\">Shared video</a><br>"
            + "Shared URL: \(videoURL)<br>"
            + "<a href=\"\(videoURL)\">How Anthropic uses Claude</a><br>"
            + "Mar 26, 2026, 11:57:04 PM CDT<br></div>"
            + "<div class=\"content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1 mdl-typography--text-right\"></div>"
            + "<div class=\"content-cell mdl-cell mdl-cell--12-col mdl-typography--caption\">"
            + "<b>Products:</b><br>\(emsp)YouTube<br></div></div></div>"
            + "</body></html>"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_activity_shared.html")
        try html.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let activities = try await YouTubeTranscriptKit.getActivity(fileURL: tempURL)
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].action, .shared)
        if case .video(let id, let title) = activities[0].link {
            XCTAssertTrue(id.hasPrefix("91AJ0cpgLlQ"))
            XCTAssertEqual(title, "How Anthropic uses Claude")
        } else {
            XCTFail("Expected .video link, got \(activities[0].link)")
        }
    }

    func testParseDismissedShelfActivity() async throws {
        let sc = String(UnicodeScalar(59))
        let emsp = "&emsp\(sc)"
        let html = "<html><body>"
            + "<div class=\"outer-cell mdl-cell mdl-cell--12-col mdl-shadow--2dp\">"
            + "<div class=\"mdl-grid\">"
            + "<div class=\"header-cell mdl-cell mdl-cell--12-col\">"
            + "<p class=\"mdl-typography--title\">YouTube<br></p></div>"
            + "<div class=\"content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1\">"
            + "Dismissed shelf<br>Jan 4, 2026, 1:48:04 PM CDT<br></div>"
            + "<div class=\"content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1 mdl-typography--text-right\"></div>"
            + "<div class=\"content-cell mdl-cell mdl-cell--12-col mdl-typography--caption\">"
            + "<b>Products:</b><br>\(emsp)YouTube<br></div></div></div>"
            + "</body></html>"

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_activity_dismissed_shelf.html")
        try html.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let activities = try await YouTubeTranscriptKit.getActivity(fileURL: tempURL)
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].action, .dismissedShelf)
        if case .none = activities[0].link {
            // expected
        } else {
            XCTFail("Expected .none link, got \(activities[0].link)")
        }
        XCTAssertNil(activities[0].link.url)
    }

    // MARK: - Action Enum

    func testActionRawValues() {
        XCTAssertEqual(Activity.Action.usedShortsCreationTools.rawValue, "used shorts creation tools")
        XCTAssertEqual(Activity.Action.watched.rawValue, "watched")
        XCTAssertEqual(Activity.Action.dismissed.rawValue, "dismissed")
        XCTAssertEqual(Activity.Action.dismissedShelf.rawValue, "dismissed shelf")
        XCTAssertEqual(Activity.Action.shared.rawValue, "shared")
    }

    // MARK: - Link URL

    func testLinkNoneURL() {
        let link = Activity.Link.none
        XCTAssertNil(link.url)
    }

    func testLinkVideoURL() {
        let link = Activity.Link.video(id: "abc123", title: "Test")
        XCTAssertEqual(link.url?.absoluteString, "https://www.youtube.com/watch?v=abc123")
    }
}
