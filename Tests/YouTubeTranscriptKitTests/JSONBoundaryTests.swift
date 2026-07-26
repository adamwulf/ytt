import XCTest
@testable import YouTubeTranscriptKit

/// `leadingJSONValueBytes` is general-purpose — it knows nothing about YouTube — so these exercise it
/// directly, including inputs no watch page would produce. Page-level behaviour lives in
/// `TrailingScriptTests`.
final class JSONBoundaryTests: XCTestCase {

    private static let trailing = WatchPage.trailingScript

    func testRecoversFromTrailingStatements() {
        let json = #"{"a":1}"#
        let recovered = leadingJSONValueBytes(in: Data((json + Self.trailing).utf8))
        XCTAssertEqual(String(data: recovered ?? Data(), encoding: .utf8), json)
    }

    func testLeavesCleanJSONUntouched() {
        let data = Data(#"{"a":{"b":[1,2,3]}}"#.utf8)
        XCTAssertEqual(leadingJSONValueBytes(in: data), data)
    }

    /// The cases a hand-rolled brace counter gets wrong. The real parser owns escape handling, so
    /// there is no bespoke state machine here to drift out of spec.
    func testHandlesBracesAndTerminatorsInsideStrings() {
        let cases = [
            #"{"a":"}"}"#,                       // brace in string
            #"{"a":"\"}"}"#,                     // escaped quote then brace
            #"{"a":"\\"}"#,                      // trailing backslash
            #"{"a":"</script>"}"#,               // script tag in string
            #"{"a":";</script>"}"#,              // the terminator itself, in a string
            #"{"a":{"b":{"c":"}"}},"d":[1,"{"]}"#
        ]

        for json in cases {
            let recovered = leadingJSONValueBytes(in: Data((json + Self.trailing).utf8))
            XCTAssertEqual(String(data: recovered ?? Data(), encoding: .utf8), json,
                           "Failed to recover \(json) byte-exactly")
        }
    }

    /// The reported index is a byte offset, so anything that makes bytes and characters disagree —
    /// emoji, accents, CJK — lands the boundary in the wrong place if it is ever treated as a
    /// character offset. Real descriptions are full of them.
    func testBoundaryIsCorrectWithMultiByteCharacters() {
        let cases = [
            #"{"a":"🟥🟦 astral pair"}"#,
            #"{"a":"café naïve"}"#,
            #"{"a":"日本語のテキスト"}"#,
            #"{"a":"mixed 🟥 café 日本"}"#
        ]

        for json in cases {
            let data = Data((json + Self.trailing).utf8)
            let recovered = leadingJSONValueBytes(in: data)
            XCTAssertEqual(String(data: recovered ?? Data(), encoding: .utf8), json)
            // Byte count, not character count: these differ for every case above.
            XCTAssertEqual(recovered?.count, json.utf8.count)
            XCTAssertNotEqual(json.utf8.count, json.count)
        }
    }

    func testRefusesFragmentsAndMalformedInput() {
        XCTAssertNil(leadingJSONValueBytes(in: Data(#"{"a":1,"b":}"#.utf8)),
                     "Malformed JSON must not yield a truncated object")
        XCTAssertNil(leadingJSONValueBytes(in: Data(#"{"a":{"b":1}"#.utf8)),
                     "Unterminated JSON must not yield a truncated object")
        XCTAssertNil(leadingJSONValueBytes(in: Data("".utf8)))
        XCTAssertNil(leadingJSONValueBytes(in: Data("not json at all".utf8)))
    }

    /// No proper prefix of a complete JSON value is itself valid JSON, so a truncated object cannot
    /// come back from this. Cutting a real player response at every closing brace is the blunt way
    /// to show it, and it is the invariant that matters most: a partial object would be persisted as
    /// a complete video record.
    func testNoTruncationOfARealResponseEverSurvives() throws {
        let page = try TrailingScriptTests.chromeUserAgentPageHTML()
        let marker = try XCTUnwrap(page.range(of: "var ytInitialPlayerResponse = "))
        let end = try XCTUnwrap(page[marker.upperBound...].range(of: WatchPage.terminator))
        let full = Data(String(page[marker.upperBound..<end.lowerBound]).utf8)

        let complete = try XCTUnwrap(leadingJSONValueBytes(in: full))
        var checked = 0

        for cut in stride(from: 1, to: complete.count, by: 97) {
            let truncated = Data(complete.prefix(cut))
            if let recovered = leadingJSONValueBytes(in: truncated) {
                // The only prefix allowed to survive is one that is already a complete value.
                XCTAssertNotNil(try? JSONSerialization.jsonObject(with: recovered))
                XCTAssertEqual(recovered.count, truncated.count,
                               "Returned a shortened object for a cut at \(cut)")
            }
            checked += 1
        }

        XCTAssertGreaterThan(checked, 50, "Sweep did not cover enough cut points to mean anything")
    }

    /// Pins the Foundation behaviour the recovery leans on. If `NSJSONSerializationErrorIndex` stops
    /// being reported, or stops pointing just past the top-level value, this fails loudly instead of
    /// the fix quietly degrading back into the original bug. Verified on macOS 26; macOS 15 changed
    /// the underlying parser, so this is the test that should be watched on the oldest supported OS.
    func testFoundationStillReportsTheErrorIndexRecoveryDependsOn() {
        let json = #"{"a":"}"}"#

        do {
            _ = try JSONSerialization.jsonObject(with: Data((json + Self.trailing).utf8))
            XCTFail("Expected trailing data to be rejected")
        } catch let error as NSError {
            XCTAssertEqual(error.userInfo["NSJSONSerializationErrorIndex"] as? Int, json.utf8.count,
                           "Recovery depends on this index pointing just past the top-level value")
        }
    }
}
