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
        let url = try youtubeURL(fromID: videoID)
        return try await getTranscript(url: url)
    }

    public static func getTranscript(url: URL) async throws -> [TranscriptMoment] {
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

        let tracks = try extractCaptionTracks(from: htmlString)
        let text = try await getTranscriptText(from: tracks)
        return text
    }

    // MARK: - Private

    /// Every `ytInitialPlayerResponse` blob embedded in a watch page, in document order.
    ///
    /// Shared so the video-info and caption paths always decode exactly the same bytes. They read
    /// the same script block, and when only one of them compensated for a trailing statement the
    /// other failed invisibly.
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
                let viewCount = Int(details.viewCount)
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
                        let captionTracks = try extractCaptionTracks(from: blobs)
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

        // The marker was present but nothing decoded, which points at a YouTube schema change
        // rather than a video that is missing, private, or deleted.
        if let lastDecodeError {
            throw TranscriptError.videoInfoParseError(lastDecodeError)
        }

        throw TranscriptError.noVideoInfo
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

    private static func getTranscriptText(from track: CaptionTrack) async throws -> [TranscriptMoment] {
        let urlString = track.baseUrl.hasPrefix("http") ? track.baseUrl : "https://www.youtube.com\(track.baseUrl)"
        guard let url = URL(string: urlString) else {
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
