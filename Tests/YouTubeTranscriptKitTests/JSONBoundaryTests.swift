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

    /// No proper prefix of a complete JSON value is itself valid JSON, so a truncated object must
    /// never come back from this. It is the invariant that matters most, because a partial object
    /// would be persisted as a complete video record.
    ///
    /// Every cut here is strictly shorter than the whole value, so ANY non-nil return is a partial
    /// object by definition — which makes nil the entire assertion. Cut points include the offset
    /// just past every closing brace, since those are the only places a balanced-looking prefix
    /// could end; a plain stride samples almost none of them.
    func testNoTruncationOfARealResponseEverSurvives() throws {
        let complete = try WatchPage.chromeUserAgentPlayerResponse()
        let tail = Data(WatchPage.trailingScript.utf8)

        var cuts = Set(complete.indices.filter { complete[$0] == UInt8(ascii: "}") }.map { $0 + 1 })
        let braceCuts = cuts.count
        cuts.formUnion(stride(from: 1, to: complete.count, by: 97))
        cuts.remove(complete.count)  // the whole value is not a truncation

        for cut in cuts.sorted() {
            let truncated = Data(complete.prefix(cut))
            XCTAssertNil(leadingJSONValueBytes(in: truncated),
                         "Cut at \(cut) survived recovery")
            // The production shape is a truncated value followed by the appended statements, which
            // is the only version of this that exercises trimming on truncated input.
            XCTAssertNil(leadingJSONValueBytes(in: truncated + tail),
                         "Cut at \(cut) with trailing statements survived recovery")
        }

        XCTAssertGreaterThan(braceCuts, 15, "Sweep missed the closing braces it claims to cover")
        XCTAssertGreaterThan(cuts.count, 50, "Sweep did not cover enough cut points to mean anything")
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
