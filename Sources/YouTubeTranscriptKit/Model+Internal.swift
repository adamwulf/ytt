//
//  MetaTag.swift
//  YouTubeTranscript
//
//  Created by Adam Wulf on 1/11/25.
//

import Foundation

// MARK: - Video Details

struct VideoResponse: Codable {
    let videoDetails: VideoDetails
    let microformat: Microformat
}

struct Microformat: Codable {
    let playerMicroformatRenderer: PlayerMicroformat
}

struct PlayerMicroformat: Codable {
    // Nothing reads these two: the public title and description come from videoDetails. They stay
    // modelled because the microformat copies are the localized ones, but they decode leniently —
    // see RenderedText. A required field nothing reads is pure liability, and this pair proved it by
    // failing every video once YouTube switched them from runs to simpleText.
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
struct RenderedText: Codable {
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

        if let runs = try? container.decode([TextRun].self, forKey: .runs) {
            text = runs.map(\.text).joined()
        } else {
            text = try? container.decode(String.self, forKey: .simpleText)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .simpleText)
    }
}

struct TextRun: Codable {
    let text: String
}

struct LiveBroadcastDetails: Codable {
    let isLiveNow: Bool
    let startTimestamp: String
    let endTimestamp: String? // end can be nil if isLiveNow == true
}

struct VideoDetails: Codable {
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

struct ThumbnailContainer: Codable {
    let thumbnails: [Thumbnail]
}

struct Thumbnail: Codable {
    let url: String
    let width: Int
    let height: Int
}

// MARK: - Captions

struct CaptionTrack: Codable {
    public let baseUrl: String
    public let vssId: String
    public let languageCode: String
}

struct CaptionsResponse: Codable {
    public let captions: CaptionsData
}

struct CaptionsData: Codable {
    public let playerCaptionsTracklistRenderer: CaptionTrackList
}

struct CaptionTrackList: Codable {
    public let captionTracks: [CaptionTrack]
}
