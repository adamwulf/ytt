//
//  MetaTag.swift
//  YouTubeTranscript
//
//  Created by Adam Wulf on 1/11/25.
//

import Foundation

// MARK: - Video Details

struct VideoResponse: Decodable {
    let videoDetails: VideoDetails
    let microformat: Microformat
}

struct Microformat: Decodable {
    let playerMicroformatRenderer: PlayerMicroformat
}

struct PlayerMicroformat: Decodable {
    // Nothing reads these two: the public title and description come from videoDetails. They stay
    // modelled because the microformat copies are the localized ones, but they decode leniently —
    // see RenderedText. A required field nothing reads is pure liability, and this pair proved it by
    // failing every video once YouTube switched them from runs to simpleText.
    //
    // Optional and lenient defend against different changes, and both are load-bearing: the decoder
    // covers a value arriving in an unfamiliar shape, the `?` covers the key disappearing entirely.
    let title: RenderedText?
    let description: RenderedText?
    let lengthSeconds: String
    let externalChannelId: String
    let category: String
    let publishDate: String
    let uploadDate: String
    let ownerChannelName: String
    let ownerProfileUrl: String
    let liveBroadcastDetails: LiveBroadcastDetails?
}

/// Text that YouTube renders either as `{"runs":[{"text":"..."}]}` or `{"simpleText":"..."}`.
///
/// Which one appears varies by field and changes over time, so both are accepted, and any other
/// shape decodes to a nil `text` rather than throwing. That leniency is deliberate but narrow: it
/// belongs to fields nothing depends on. Everything the parser actually reads stays strict, so a
/// schema change that matters still surfaces as `videoInfoParseError` instead of quietly vanishing.
struct RenderedText: Decodable {
    let text: String?

    private enum CodingKeys: String, CodingKey {
        case runs
        case simpleText
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            text = nil
            return
        }

        // An empty runs array joins to "", not nil: the field was present and well formed, it just
        // carried no text. Only a shape this does not recognise gives up and reports nil.
        if let runs = try? container.decode([TextRun].self, forKey: .runs) {
            text = runs.map(\.text).joined()
        } else {
            text = try? container.decode(String.self, forKey: .simpleText)
        }
    }
}

struct TextRun: Decodable {
    let text: String
}

struct LiveBroadcastDetails: Decodable {
    let isLiveNow: Bool
    let startTimestamp: String
    let endTimestamp: String? // end can be nil if isLiveNow == true
}

struct VideoDetails: Decodable {
    let videoId: String
    let title: String
    let lengthSeconds: String
    let channelId: String
    let shortDescription: String
    let viewCount: String
    let author: String
    let thumbnail: ThumbnailContainer
    let isLiveContent: Bool
}

struct ThumbnailContainer: Decodable {
    let thumbnails: [Thumbnail]
}

struct Thumbnail: Decodable {
    let url: String
    let width: Int
    let height: Int
}

// MARK: - Captions

struct CaptionTrack: Decodable {
    public let baseUrl: String
    public let vssId: String
    public let languageCode: String
}

struct CaptionsResponse: Decodable {
    public let captions: CaptionsData
}

struct CaptionsData: Decodable {
    public let playerCaptionsTracklistRenderer: CaptionTrackList
}

struct CaptionTrackList: Decodable {
    public let captionTracks: [CaptionTrack]
}
