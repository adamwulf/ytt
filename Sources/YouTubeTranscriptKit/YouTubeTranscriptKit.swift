import Foundation

public enum YouTubeTranscriptKit {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

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
        case activityParseError(block: String, reason: String)
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
        do {
            var request = URLRequest(url: url)
            (data, _) = try await session.data(for: request)
        } catch {
            throw TranscriptError.networkError(error)
        }

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
        do {
            var request = URLRequest(url: url)
            (data, _) = try await session.data(for: request)
        } catch {
            throw TranscriptError.networkError(error)
        }

        guard let htmlString = String(data: data, encoding: .utf8) else {
            throw TranscriptError.invalidHTMLFormat
        }

        let tracks = try extractCaptionTracks(from: htmlString)
        let text = try await getTranscriptText(from: tracks)
        return text
    }

    // MARK: - Private

    private static func extractVideoInfo(from htmlString: String, includeTranscript: Bool) async throws -> VideoInfo {
        var searchRange = htmlString.startIndex..<htmlString.endIndex

        while let range = htmlString.range(of: "var ytInitialPlayerResponse = ", range: searchRange),
              let endRange = htmlString[range.upperBound...].range(of: ";</script>") {
            let jsonString = String(htmlString[range.upperBound..<endRange.lowerBound])

            if let jsonData = jsonString.data(using: .utf8) {
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

                    // Attempt to extract transcript if requested
                    let transcript: [TranscriptMoment]?
                    do {
                        if includeTranscript {
                            let captionTracks = try extractCaptionTracks(from: htmlString)
                            transcript = try await getTranscriptText(from: captionTracks)
                        } else {
                            transcript = nil
                        }
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
                } catch {
                    // Continue to next match on parse failure
                }
            }

            searchRange = endRange.upperBound..<htmlString.endIndex
        }

        throw TranscriptError.noVideoInfo
    }

    private static func extractCaptionTracks(from htmlString: String) throws -> [CaptionTrack] {
        var allTracks: [CaptionTrack] = []
        var searchRange = htmlString.startIndex..<htmlString.endIndex
        var matchCount = 0

        while let range = htmlString.range(of: "var ytInitialPlayerResponse = ", range: searchRange),
              let endRange = htmlString[range.upperBound...].range(of: ";</script>") {
            matchCount += 1

            let jsonString = String(htmlString[range.upperBound..<endRange.lowerBound])

            if let jsonData = jsonString.data(using: .utf8) {
                do {
                    let response = try JSONDecoder().decode(CaptionsResponse.self, from: jsonData)
                    let tracks = response.captions.playerCaptionsTracklistRenderer.captionTracks
                    allTracks.append(contentsOf: tracks)
                } catch {
                    // Silently continue to next match on parse failure
                }
            }

            searchRange = endRange.upperBound..<htmlString.endIndex
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
        do {
            var request = URLRequest(url: url)
            (data, _) = try await session.data(for: request)
        } catch {
            throw TranscriptError.networkError(error)
        }

        guard let xmlString = String(data: data, encoding: .utf8) else {
            throw TranscriptError.invalidXMLFormat
        }

        return try parseTranscriptXML(xmlString)
    }

    private static func parseTranscriptXML(_ xml: String) throws -> [TranscriptMoment] {
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
        // Extract action - now captures text up until a URL pattern
        let actionPattern = #"<div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">([^<]+?)(?:(?:https://|<a href="))"#
        guard let actionRegex = try? NSRegularExpression(pattern: actionPattern),
              let actionMatch = actionRegex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
              actionMatch.numberOfRanges > 1,
              let actionRange = Range(actionMatch.range(at: 1), in: block) else {
            guard !block.contains("Viewed a post that is no longer available") else {
                return nil
            }
            throw TranscriptError.activityParseError(block: block, reason: "Could not extract action")
        }

        let actionText = String(block[actionRange]).trimmingCharacters(in: .whitespaces).lowercased()
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
            throw TranscriptError.activityParseError(block: block, reason: "Could not extract URL")
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
        // Try anchor tag format first
        let anchorPattern = #"<a href="(?:https://)?www\.youtube\.com/watch\?v=([^"]+)">([^<]+)</a>"#
        if let regex = try? NSRegularExpression(pattern: anchorPattern),
           let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
           match.numberOfRanges > 2,
           let idRange = Range(match.range(at: 1), in: block),
           let titleRange = Range(match.range(at: 2), in: block) {
            let id = String(block[idRange])
            let title = String(block[titleRange])

            // If title is just the URL, treat it as no title
            if title == "https://www.youtube.com/watch?v=\(id)" {
                return (id, nil)
            }
            return (id, title.stringByDecodingHTMLEntities)
        }

        // Try plain URL format
        let plainPattern = #"https://www\.youtube\.com/watch\?v=([^<\s]+)"#
        if let regex = try? NSRegularExpression(pattern: plainPattern),
           let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
           match.numberOfRanges > 1,
           let idRange = Range(match.range(at: 1), in: block) {
            return (String(block[idRange]), nil)
        }

        return nil
    }

    private static func extractPostId(from block: String) throws -> (id: String, text: String)? {
        let pattern = #"<a href="(?:https://)?www\.youtube\.com/post/([^"]+)">([^<]+)</a>"#
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
        let pattern = #"<a href="(?:https://)?www\.youtube\.com/channel/([^"]+)">([^<]+)</a>"#
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
        let pattern = #"<a href="(?:https://)?www\.youtube\.com/playlist\?list=([^"]+)">([^<]+)</a>"#
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
        let pattern = #"<a href="(?:https://)?www\.youtube\.com/results\?search_query=([^"]+)">([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..<block.endIndex, in: block)),
              match.numberOfRanges > 1,
              let queryRange = Range(match.range(at: 1), in: block) else {
            return nil
        }
        return String(block[queryRange]).stringByDecodingHTMLEntities
    }
}
