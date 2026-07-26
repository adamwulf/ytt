import Foundation

/// The bytes of the first complete JSON value in `data`, ignoring anything that follows it.
///
/// Embedded JSON does not always end where the surrounding document says it does. A blob sliced out
/// of an HTML script block can pick up whatever statements follow the JSON in the same block, and
/// every JSON API in Foundation rejects trailing data — `JSONSerialization` with `Data` or with an
/// `InputStream`, and `JSONDecoder` alike. So the end of the value has to be found some other way.
///
/// It is found by asking the parser, which already reports it. A hand-written scanner would have to
/// track strings and escapes to know that the `}` in `{"a":"}"}` is not the end, and would amount to
/// a second JSON implementation waiting to disagree with the first.
///
/// Returns nil when the leading bytes are not themselves a complete value, so a caller can never be
/// handed a fragment. That re-parse is defence in depth rather than the thing that keeps a malformed
/// response loud: no proper prefix of a complete JSON value is itself valid JSON, so a truncated
/// object cannot survive it in the first place. It costs one parse on an already-failing input and
/// makes the contract true by construction instead of by argument.
///
/// The index this relies on is `NSJSONSerializationErrorIndex`, which is long-standing but not a
/// documented guarantee. If a Foundation release stops reporting it, the trailing bytes stop being
/// trimmed and decoding fails loudly rather than silently returning bad data; `JSONBoundaryTests`
/// pins the behaviour so that change is visible. Verified on macOS 26. Note this package supports
/// back to macOS 13, and macOS 15 replaced the parser with the swift-foundation implementation, so
/// the guarantee is worth re-checking on the oldest supported OS in CI.
func leadingJSONValueBytes(in data: Data) -> Data? {
    do {
        _ = try JSONSerialization.jsonObject(with: data)
        return data
    } catch let error as NSError {
        // Reported as a byte offset, not a character offset — the two differ on any page with
        // multi-byte UTF-8 in it, which for YouTube descriptions is most of them.
        guard let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int,
              index > 0, index <= data.count else {
            return nil
        }

        let prefix = Data(data.prefix(index))
        guard (try? JSONSerialization.jsonObject(with: prefix)) != nil else { return nil }
        return prefix
    }
}
