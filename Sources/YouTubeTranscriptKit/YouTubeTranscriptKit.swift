import Foundation

public enum YouTubeTranscriptKit {
    // The session every fetch runs through, and the `configure(_:)` hook that builds it, live in
    // Configuration.swift.

    public enum TranscriptError: Error {
        case invalidURL
        case invalidVideoID
        case networkError(Error)
        case noTranscriptData
        case invalidHTMLFormat
        case jsonParsingError(Error)
        case noCaptionData
        case invalidXMLFormat
        case noVideoInfo
        case videoInfoParseError(Error)
        /// The page loaded and said the video cannot be played.
        ///
        /// Distinct from `videoInfoParseError` on purpose — that one means YouTube changed their
        /// schema, and reporting it for a deleted video sends whoever reads it looking for a bug in
        /// this parser. `status` is YouTube's own code, verbatim and unmapped, so a caller can
        /// classify on it rather than on English prose; `reason` carries the prose for a human, and
        /// is absent for the statuses that ship without one.
        ///
        /// Whether it is permanent depends on the status, and this case deliberately does not decide:
        /// `ERROR` (deleted) and `UNPLAYABLE` (members-only) are the two captured in fixtures and
        /// both are permanent. `LOGIN_REQUIRED` is not safely either — YouTube uses it for a private
        /// video, which is permanent, and also for its "Sign in to confirm you're not a bot" wall,
        /// which is a soft ban and the most transient thing there is. That wall arrives as a 200 on a
        /// page `isCaptchaWall` cannot see, since it only matches the `/sorry` redirect, so nothing
        /// upstream catches it first. A caller that files every `videoUnavailable` permanently would
        /// write off every video fetched during a ban.
        ///
        /// No fixture of that page exists yet, so the reason text that would distinguish it is
        /// unverified and nothing here matches on it — guessing at prose we have never seen would be
        /// the same mistake in the other direction. Until one is captured, treat `LOGIN_REQUIRED` as
        /// needing its reason inspected.
        ///
        /// Do not read that as "every other status is permanent". `LIVE_STREAM_OFFLINE` is a stream
        /// that has not started, which is as transient as it gets, and it does not arrive here today
        /// only because such a page carries `videoDetails` and decodes — the status is never consulted
        /// for it. What reaches this error is narrow by construction: a payload that yielded nothing
        /// usable at all. A caller classifying on `status` should still default to retrying anything
        /// it does not recognise rather than filing it permanently.
        case videoUnavailable(status: String, reason: String?)
        case rateLimited(statusCode: Int, url: URL?)
        case httpError(statusCode: Int, url: URL?)
        case activityParseError(block: String, reason: String)
    }

    /// Rejects a response that carries no usable page, so a soft ban is not mistaken for a missing video.
    ///
    /// When Google rate limits a client it answers with a 302 to `google.com/sorry/...`, its
    /// "unusual traffic from your computer network" CAPTCHA wall. URLSession follows that redirect
    /// transparently, so the status code we observe is 200 and only the final URL reveals the ban.
    /// Checking the status code alone misses it.
    static func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }

        if isCaptchaWall(httpResponse.url) || httpResponse.statusCode == 429 {
            throw TranscriptError.rateLimited(statusCode: httpResponse.statusCode, url: httpResponse.url)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranscriptError.httpError(statusCode: httpResponse.statusCode, url: httpResponse.url)
        }
    }

    /// Whether a URL points at Google's CAPTCHA wall, matching country domains as well as google.com.
    static func isCaptchaWall(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased(), url.path.hasPrefix("/sorry") else { return false }

        // Match google.com and country domains such as google.co.uk, but not lookalikes like
        // "notgoogle.com" or "google.com.example.net", by requiring "google" to be its own
        // component within the last three (allowing a two-part suffix like ".co.uk").
        let components = host.split(separator: ".")
        guard let index = components.firstIndex(of: "google") else { return false }
        return index >= components.count - 3
    }

    /// Whether an error means the fetch failed in a way that retrying later could fix.
    ///
    /// These propagate unwrapped so callers can back off instead of recording a partial result as a
    /// success. Permanent failures are deliberately excluded: a caption track that is gone for good
    /// answers 404 or 403 every time, and throwing for it would strand any caller that only marks a
    /// video done on success, leaving it to retry that video every run and never drain its queue.
    /// `videoUnavailable` is excluded too: a deleted video will still be deleted next run, and a
    /// caller that retries it is the queue that never drains. That holds for the statuses whose
    /// permanence is established — see the case's own doc for `LOGIN_REQUIRED`, which is not one of
    /// them. This function is internal and only guards the caption fetch, where `videoUnavailable`
    /// cannot arise, so the ambiguity is the caller's to resolve and not decided here.
    static func isTransientFetchFailure(_ error: Error) -> Bool {
        guard let error = error as? TranscriptError else { return false }

        switch error {
        case .rateLimited, .networkError:
            return true
        case .httpError(let statusCode, _):
            // 429 never reaches here; validate() turns it into rateLimited first.
            return statusCode >= 500
        default:
            return false
        }
    }

    private static func youtubeURL(fromID videoID: String) throws -> URL {
        guard !videoID.isEmpty else {
            throw TranscriptError.invalidVideoID
        }

        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
            throw TranscriptError.invalidURL
        }

        return url
    }

    // MARK: - Video Info

    public static func getVideoInfo(videoID: String, includeTranscript: Bool = true) async throws -> VideoInfo {
        let url = try youtubeURL(fromID: videoID)
        return try await getVideoInfo(url: url, includeTranscript: includeTranscript)
    }

    public static func getVideoInfo(url: URL, includeTranscript: Bool = true) async throws -> VideoInfo {
        let data: Data
        let response: URLResponse
        do {
            let request = URLRequest(url: url)
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriptError.networkError(error)
        }

        try validate(response)

        guard let htmlString = String(data: data, encoding: .utf8) else {
            throw TranscriptError.invalidHTMLFormat
        }

        let videoInfo = try await extractVideoInfo(from: htmlString, includeTranscript: includeTranscript)
        return videoInfo
    }

    // MARK: - Transcripts

    public static func getTranscript(videoID: String) async throws -> [TranscriptMoment] {
        let tracks = try await fetchCaptionTracks(videoID: videoID)
        return try await getTranscriptText(from: tracks)
    }

    public static func getTranscript(url: URL) async throws -> [TranscriptMoment] {
        guard let videoID = videoID(from: url) else {
            throw TranscriptError.invalidURL
        }
        return try await getTranscript(videoID: videoID)
    }

    // MARK: - Caption tracks (InnerTube)

    /// The caption tracks for a video, fetched from the InnerTube player endpoint.
    ///
    /// The caption `baseUrl`s embedded in the public watch page's `ytInitialPlayerResponse` no longer
    /// return anything: a request to one answers `200` with an empty body, which is why fetching a
    /// transcript from the watch page now fails with `noTranscriptData` even though the page still
    /// lists the tracks. Posting to `youtubei/v1/player` as the ANDROID client returns the same
    /// caption schema (`captions.playerCaptionsTracklistRenderer.captionTracks`) with fresh `baseUrl`s
    /// that do return content. What earns the working URLs is the `ANDROID` client in the body, not
    /// the transport identity: no API key or cookie is needed, and the request succeeds whatever the
    /// `User-Agent` is. So this sets only `Content-Type` and otherwise leaves the session's headers
    /// alone — the consumer's configured identity, if any, still rides every request uniformly, which
    /// is the invariant `ConfigurationTests` pins.
    ///
    /// Video metadata still comes from the watch page, because this ANDROID response carries no
    /// `microformat` and so cannot supply the category and dates `getVideoInfo` returns.
    static func fetchCaptionTracks(videoID: String) async throws -> [CaptionTrack] {
        guard !videoID.isEmpty else {
            throw TranscriptError.invalidVideoID
        }
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player") else {
            throw TranscriptError.invalidURL
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "20.10.38",
                    "androidSdkVersion": 30,
                    "hl": "en",
                    "gl": "US"
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriptError.networkError(error)
        }

        try validate(response)

        return try extractCaptionTracks(from: [data])
    }

    /// The `v` video id carried by a YouTube watch URL, or the path id of a `youtu.be` short URL.
    static func videoID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        if let host = url.host?.lowercased(), host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }

        if let value = components.queryItems?.first(where: { $0.name == "v" })?.value, !value.isEmpty {
            return value
        }

        return nil
    }

    // MARK: - Private

    /// Every `ytInitialPlayerResponse` blob embedded in a watch page, in document order.
    ///
    /// The video-info metadata decode and the HTML caption extraction both read these blobs, so they
    /// always decode exactly the same bytes: when only one of them compensated for a trailing
    /// statement the other failed invisibly. Production caption fetching no longer reads the watch
    /// page at all — its tracks come from InnerTube, see `fetchCaptionTracks(videoID:)` — but
    /// `extractCaptionTracks(from:String)` still parses these blobs and its unit tests still pin it.
    ///
    /// The slice runs to the first `;</script>`, which ends the statement but is not always the end
    /// of the JSON — YouTube appends further statements to the same block for some clients, leaving
    /// the decoder with `{...};var meta = ...`. `leadingJSONValueBytes` trims that back off.
    ///
    /// A literal `;</script>` *inside* the JSON would cut the slice short instead, and no amount of
    /// trimming recovers that. It does not arise because YouTube escapes forward slashes in these
    /// blobs, so the sequence appears as `<\/script>`. If it ever did arise, the video-info path
    /// would report a parse error — `testLiteralTerminatorInsideJSONFailsLoudly` pins that — while
    /// the caption path would report `noCaptionData`, since it has no way to distinguish a broken
    /// blob from a video that simply has no captions.
    static func playerResponseBlobs(in htmlString: String) -> [Data] {
        var blobs: [Data] = []
        var searchRange = htmlString.startIndex..<htmlString.endIndex

        while let range = htmlString.range(of: "var ytInitialPlayerResponse = ", range: searchRange),
              let endRange = htmlString[range.upperBound...].range(of: ";</script>") {
            if let data = String(htmlString[range.upperBound..<endRange.lowerBound]).data(using: .utf8) {
                // Untrimmable bytes are passed through rather than dropped: the caller's decode then
                // fails with the real reason, which is worth far more than a silently missing blob.
                blobs.append(leadingJSONValueBytes(in: data) ?? data)
            }

            searchRange = endRange.upperBound..<htmlString.endIndex
        }

        return blobs
    }

    static func extractVideoInfo(from htmlString: String, includeTranscript: Bool) async throws -> VideoInfo {
        var lastDecodeError: Error?
        // Sliced once and handed to the caption path below, which would otherwise re-scan the page
        // and re-trim every blob to reach the same bytes.
        let blobs = playerResponseBlobs(in: htmlString)

        for jsonData in blobs {
            do {
                let response = try JSONDecoder().decode(VideoResponse.self, from: jsonData)
                let details = response.videoDetails
                let microformat = response.microformat.playerMicroformatRenderer

                // Parse dates
                let dateFormatter = ISO8601DateFormatter()
                let publishedAt = dateFormatter.date(from: microformat.publishDate)
                let uploadedAt = dateFormatter.date(from: microformat.uploadDate)

                // Convert string values to appropriate types
                let viewCount = details.viewCount.flatMap { Int($0) }
                let lengthSeconds = Int(details.lengthSeconds)

                // Convert thumbnails
                let thumbnails = details.thumbnail.thumbnails.map { thumb in
                    VideoThumbnail(url: thumb.url, width: thumb.width, height: thumb.height)
                }

                // Build URLs
                let channelURL = URL(string: "https://www.youtube.com/channel/\(details.channelId)")
                let videoURL = URL(string: "https://www.youtube.com/watch?v=\(details.videoId)")

                // Attempt to extract transcript if requested.
                // Captions that are absent or permanently unavailable degrade to a nil
                // transcript, which is the ordinary case. A ban or other transient failure must
                // instead fail the whole call: degrading it would return a VideoInfo that looks
                // complete while silently missing a transcript the video really has, and
                // callers cannot tell that apart from a video with no captions at all.
                let transcript: [TranscriptMoment]?
                do {
                    if includeTranscript {
                        // Captions come from the InnerTube player endpoint, not from these blobs: the
                        // caption baseUrls the watch page embeds now answer 200 with an empty body.
                        // See fetchCaptionTracks(videoID:) for the why.
                        let captionTracks = try await fetchCaptionTracks(videoID: details.videoId)
                        transcript = try await getTranscriptText(from: captionTracks)
                    } else {
                        transcript = nil
                    }
                } catch let error where isTransientFetchFailure(error) {
                    throw error
                } catch {
                    transcript = nil
                }

                return VideoInfo(
                    videoId: details.videoId,
                    title: details.title,
                    channelId: details.channelId,
                    channelName: details.author,
                    description: details.shortDescription,
                    publishedAt: publishedAt,
                    uploadedAt: uploadedAt,
                    viewCount: viewCount,
                    duration: lengthSeconds,
                    category: microformat.category,
                    isLive: microformat.liveBroadcastDetails?.isLiveNow,
                    thumbnails: thumbnails,
                    channelURL: channelURL,
                    videoURL: videoURL,
                    transcript: transcript
                )
            } catch let error as DecodingError {
                // Continue to next match on parse failure, but remember why this one failed.
                // If no match ever decodes, that error says far more than a bare noVideoInfo.
                lastDecodeError = error
            } catch {
                // Only a decode failure means a schema change. Anything else reaching here came
                // from the fetch above, and disguising it as videoInfoParseError would break
                // `if case .rateLimited` for callers and hide the ban all over again.
                throw error
            }
        }

        // Nothing decoded. Before calling that a schema change, ask the payload why: a video that is
        // deleted, private or otherwise blocked says so in playabilityStatus, and on a deleted page
        // that is the only key the parser can act on at all.
        //
        // Deliberately after the loop, not before it. A members-only video reports a non-OK status
        // and still carries complete metadata, which decodes and is worth keeping; only a payload
        // that yields nothing usable is reported unavailable.
        if let status = playabilityStatus(in: blobs), status.status != "OK" {
            throw TranscriptError.videoUnavailable(status: status.status, reason: status.reason)
        }

        // The marker was present, nothing decoded, and the payload does not claim the video is gone,
        // which points at a YouTube schema change.
        if let lastDecodeError {
            throw TranscriptError.videoInfoParseError(lastDecodeError)
        }

        throw TranscriptError.noVideoInfo
    }

    /// The playability status of the first blob that carries a readable one.
    ///
    /// Only ever consulted once `VideoResponse` has failed against every blob, so a blob that does
    /// not carry the key is simply skipped: the caller already has a decode error to fall back on,
    /// and one that names the field it wanted says more than a failure to find this one.
    static func playabilityStatus(in blobs: [Data]) -> PlayabilityStatus? {
        for jsonData in blobs {
            if let response = try? JSONDecoder().decode(PlayabilityResponse.self, from: jsonData) {
                return response.playabilityStatus
            }
        }

        return nil
    }

    static func extractCaptionTracks(from htmlString: String) throws -> [CaptionTrack] {
        return try extractCaptionTracks(from: playerResponseBlobs(in: htmlString))
    }

    static func extractCaptionTracks(from blobs: [Data]) throws -> [CaptionTrack] {
        var allTracks: [CaptionTrack] = []

        for jsonData in blobs {
            do {
                let response = try JSONDecoder().decode(CaptionsResponse.self, from: jsonData)
                let tracks = response.captions.playerCaptionsTracklistRenderer.captionTracks
                allTracks.append(contentsOf: tracks)
            } catch {
                // A video with no captions is the ordinary case and reaches here as a missing key,
                // so a decode failure cannot be told apart from "no captions" and the loop moves on.
                // That tolerance is why a malformed blob is invisible here: it surfaces as
                // noCaptionData, which callers treat as a no-op rather than an error.
                //
                // It is also why getTranscript() on a deleted video reports noCaptionData rather than
                // videoUnavailable: this path has no error to report and no equivalent playability
                // check. getVideoInfo() is the entry point that tells them apart. Adding the check
                // here would mean deciding that an unplayable video must fail the caption fetch,
                // which is the opposite of what the tolerance above exists for.
            }
        }

        guard !allTracks.isEmpty else {
            throw TranscriptError.noCaptionData
        }

        // Sort tracks: English first (prioritizing non 'a' vssId), then others
        return allTracks.sorted { track1, track2 in
            if track1.languageCode == "en" && track2.languageCode != "en" {
                return true
            }
            if track1.languageCode != "en" && track2.languageCode == "en" {
                return false
            }
            if track1.languageCode == "en" && track2.languageCode == "en" {
                let track1StartsWithA = track1.vssId.hasPrefix("a")
                let track2StartsWithA = track2.vssId.hasPrefix("a")
                return track1StartsWithA == track2StartsWithA ? true : !track1StartsWithA
            }
            return true
        }
    }

    private static func getTranscriptText(from tracks: [CaptionTrack]) async throws -> [TranscriptMoment] {
        for track in tracks {
            do {
                return try await getTranscriptText(from: track)
            } catch let error where isTransientFetchFailure(error) {
                // A ban or server failure will meet every remaining track too, and walking the rest
                // would only bury the reason under a misleading noTranscriptData. Fail with the
                // real cause instead.
                throw error
            } catch {
                continue
            }
        }
        throw TranscriptError.noTranscriptData
    }

    /// A caption `baseUrl` with its transcript format pinned to `srv1`.
    ///
    /// InnerTube hands back a `baseUrl` ending in `fmt=srv3`, the word-timed format whose `<p><s>`
    /// markup `parseTranscriptXML` cannot read. `srv1` is the classic `<transcript><text start dur>`
    /// shape the parser expects. `fmt` is not among the signed `sparams`, so replacing it leaves the
    /// signature valid.
    ///
    /// The query is edited as raw text rather than through `URLComponents`, which would re-encode the
    /// signature and `sparams` and could break the signature. Only the `fmt` pair is touched; every
    /// other pair is preserved byte for byte.
    static func captionURL(fromBaseURL urlString: String) -> URL? {
        let parts = urlString.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = String(parts[0])
        let existingQuery = parts.count > 1 ? String(parts[1]) : ""

        var pairs = existingQuery.split(separator: "&", omittingEmptySubsequences: true).map(String.init)
        pairs.removeAll { $0 == "fmt" || $0.hasPrefix("fmt=") }
        pairs.append("fmt=srv1")

        return URL(string: base + "?" + pairs.joined(separator: "&"))
    }

    private static func getTranscriptText(from track: CaptionTrack) async throws -> [TranscriptMoment] {
        let urlString = track.baseUrl.hasPrefix("http") ? track.baseUrl : "https://www.youtube.com\(track.baseUrl)"
        guard let url = captionURL(fromBaseURL: urlString) else {
            throw TranscriptError.invalidURL
        }

        let data: Data
        let response: URLResponse
        do {
            let request = URLRequest(url: url)
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriptError.networkError(error)
        }

        try validate(response)

        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw TranscriptError.invalidXMLFormat
        }

        return try parseTranscriptXML(xmlString)
    }

    static func parseTranscriptXML(_ xml: String) throws -> [TranscriptMoment] {
        var moments: [TranscriptMoment] = []
        var searchRange = xml.startIndex..<xml.endIndex

        while let startTagRange = xml.range(of: #"<text start="([^"]+)" dur="([^"]+)">"#, options: .regularExpression, range: searchRange),
              let endTagRange = xml[startTagRange.upperBound...].range(of: "</text>") {

            let attributes = xml[startTagRange]
            guard let startMatch = attributes.range(of: #"start="([^"]+)""#, options: .regularExpression),
                  let durMatch = attributes.range(of: #"dur="([^"]+)""#, options: .regularExpression),
                  let start = Double(xml[startMatch].dropFirst(7).dropLast()),
                  let duration = Double(xml[durMatch].dropFirst(5).dropLast()) else {
                searchRange = endTagRange.upperBound..<xml.endIndex
                continue
            }

            let xmlContent = String(xml[startTagRange.upperBound..<endTagRange.lowerBound])
            let htmlContent = xmlContent.stringByDecodingHTMLEntities
            let textContent = htmlContent.stringByDecodingHTMLEntities

            moments.append(TranscriptMoment(start: start, duration: duration, text: textContent))
            searchRange = endTagRange.upperBound..<xml.endIndex
        }

        guard !moments.isEmpty else {
            throw TranscriptError.noTranscriptData
        }

        return moments
    }

    // MARK: - Activity

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy, h:mm:ss a zzz"
        return formatter
    }()

    public static func getActivity(fileURL: URL) async throws -> [Activity] {
        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw TranscriptError.invalidHTMLFormat
        }

        var activities: [Activity] = []
        let pattern = #"<div class="outer-cell mdl-cell mdl-cell--12-col mdl-shadow--2dp">.*?</div>\s*</div>\s*</div>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(content.startIndex..<content.endIndex, in: content)

        let matches = regex.matches(in: content, options: [], range: range)
        for match in matches {
            if let range = Range(match.range, in: content) {
                let block = String(content[range])
                if let activity = try parseActivityBlock(block) {
                    activities.append(activity)
                }
            }
        }

        return activities
    }

    private static func parseActivityBlock(_ block: String) throws -> Activity? {
        // Skip activities for unavailable content
        guard !block.contains("Viewed a post that is no longer available"),
              !block.contains("Dismissed a video that is no longer available") else {
            return nil
        }

        // Extract action text from the content cell.
        // First try the pattern where action text is followed by a URL or anchor tag.
        // If that fails, try the pattern where action text is followed by <br> (no link).
        // Finally, try the pattern where the action is inside the first anchor tag (e.g., "Shared video").
        let actionWithLinkPattern = #"<div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">([^<]+?)(?:(?:https://|<a href="))"#
        let actionNoLinkPattern = #"<div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">([^<]+?)<br>"#
        let actionInLinkPattern = #"<div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1"><a href="[^"]+">(\w+) \w+</a>"#

        let actionText: String

        if let actionRegex = try? NSRegularExpression(pattern: actionWithLinkPattern),
           let actionMatch = actionRegex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
           actionMatch.numberOfRanges > 1,
           let actionRange = Range(actionMatch.range(at: 1), in: block) {
            actionText = String(block[actionRange]).trimmingCharacters(in: .whitespaces).lowercased()
        } else if let actionRegex = try? NSRegularExpression(pattern: actionNoLinkPattern),
                  let actionMatch = actionRegex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
                  actionMatch.numberOfRanges > 1,
                  let actionRange = Range(actionMatch.range(at: 1), in: block) {
            actionText = String(block[actionRange]).trimmingCharacters(in: .whitespaces).lowercased()
        } else if let actionRegex = try? NSRegularExpression(pattern: actionInLinkPattern),
                  let actionMatch = actionRegex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
                  actionMatch.numberOfRanges > 1,
                  let actionRange = Range(actionMatch.range(at: 1), in: block) {
            actionText = String(block[actionRange]).trimmingCharacters(in: .whitespaces).lowercased()
        } else {
            throw TranscriptError.activityParseError(block: block, reason: "Could not extract action")
        }

        guard let action = Activity.Action(rawValue: actionText) else {
            throw TranscriptError.activityParseError(block: block, reason: "Unsupported activity type: \(actionText)")
        }

        // Extract URL and parse into Link type
        let link: Activity.Link

        // Try each URL pattern in sequence
        if let (id, title) = try? extractVideoId(from: block) {
            link = .video(id: id, title: title)
        } else if let (id, text) = try? extractPostId(from: block) {
            link = .post(id: id, text: text)
        } else if let (id, name) = try? extractChannelId(from: block) {
            link = .channel(id: id, name: name)
        } else if let (id, title) = try? extractPlaylistId(from: block) {
            link = .playlist(id: id, title: title)
        } else if let query = try? extractSearchQuery(from: block) {
            link = .search(query: query)
        } else {
            link = .none
        }

        // Extract timestamp
        let datePattern = #"<br>([^<]+(?:AM|PM) [A-Z]+)"#
        guard let dateRegex = try? NSRegularExpression(pattern: datePattern),
              let dateMatch = dateRegex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
              dateMatch.numberOfRanges > 1,
              let dateRange = Range(dateMatch.range(at: 1), in: block),
              let date = dateFormatter.date(from: String(block[dateRange])) else {
            throw TranscriptError.activityParseError(block: block, reason: "Could not extract timestamp")
        }

        return Activity(action: action, link: link, timestamp: date)
    }

    private static func extractVideoId(from block: String) throws -> (id: String, title: String?)? {
        // Try anchor tag format first.
        // Use the last match to prefer the actual video title over action descriptions
        // (e.g., "Shared video" links repeat the URL but the last anchor has the real title).
        let anchorPattern = #"<a href="(?:https://)?(?:www\.)?youtube\.com/watch\?v=([^"]+)">([^<]+)</a>"#
        if let regex = try? NSRegularExpression(pattern: anchorPattern) {
            let matches = regex.matches(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block))
            if let match = matches.last,
               match.numberOfRanges > 2,
               let idRange = Range(match.range(at: 1), in: block),
               let titleRange = Range(match.range(at: 2), in: block) {
                let id = String(block[idRange])
                let title = String(block[titleRange])

                // If title is just the URL, treat it as no title
                if title.hasSuffix("watch?v=\(id)") {
                    return (id, nil)
                }
                return (id, title.stringByDecodingHTMLEntities)
            }
        }

        // Try plain URL format
        let plainPattern = #"https://(?:www\.)?youtube\.com/watch\?v=([^<\s]+)"#
        if let regex = try? NSRegularExpression(pattern: plainPattern),
           let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
           match.numberOfRanges > 1,
           let idRange = Range(match.range(at: 1), in: block) {
            return (String(block[idRange]), nil)
        }

        return nil
    }

    private static func extractPostId(from block: String) throws -> (id: String, text: String)? {
        let pattern = #"<a href="(?:https://)?(?:www\.)?youtube\.com/post/([^"]+)">([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
              match.numberOfRanges > 2,
              let idRange = Range(match.range(at: 1), in: block),
              let textRange = Range(match.range(at: 2), in: block) else {
            return nil
        }
        return (String(block[idRange]), String(block[textRange]).stringByDecodingHTMLEntities)
    }

    private static func extractChannelId(from block: String) throws -> (id: String, name: String)? {
        let pattern = #"<a href="(?:https://)?(?:www\.)?youtube\.com/channel/([^"]+)">([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
              match.numberOfRanges > 2,
              let idRange = Range(match.range(at: 1), in: block),
              let nameRange = Range(match.range(at: 2), in: block) else {
            return nil
        }
        return (String(block[idRange]), String(block[nameRange]).stringByDecodingHTMLEntities)
    }

    private static func extractPlaylistId(from block: String) throws -> (id: String, title: String)? {
        let pattern = #"<a href="(?:https://)?(?:www\.)?youtube\.com/playlist\?list=([^"]+)">([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
              match.numberOfRanges > 2,
              let idRange = Range(match.range(at: 1), in: block),
              let titleRange = Range(match.range(at: 2), in: block) else {
            return nil
        }
        return (String(block[idRange]), String(block[titleRange]).stringByDecodingHTMLEntities)
    }

    private static func extractSearchQuery(from block: String) throws -> String? {
        let pattern = #"<a href="(?:https://)?(?:www\.)?youtube\.com/results\?search_query=([^"]+)">([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
              match.numberOfRanges > 1,
              let queryRange = Range(match.range(at: 1), in: block) else {
            return nil
        }
        return String(block[queryRange]).stringByDecodingHTMLEntities
    }
}
