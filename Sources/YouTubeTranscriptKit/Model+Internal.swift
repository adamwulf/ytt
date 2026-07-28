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
    // Read by extractVideoInfo, so they stay required. These reach callers, and a change to one of
    // them should stop the pipeline rather than quietly blank a field on every video.
    //
    // Being read is what earns a field that treatment, but it is not sufficient on its own — see
    // VideoDetails.viewCount, which is read and still optional. The real test is whether absence
    // would mean the parser has stopped understanding the payload. For these three it would.
    let category: String
    let publishDate: String
    let uploadDate: String
    // Read too, and optional because a video that is not a broadcast simply has no such details.
    let liveBroadcastDetails: LiveBroadcastDetails?

    // Nothing reads the rest. They stay modelled as a record of what the payload carries, but every
    // one is optional, because a required field nothing reads is pure liability — this struct has
    // already proved that once, when title and description failed every video the day YouTube
    // switched them from runs to simpleText. The two defences are different: RenderedText absorbs a
    // value arriving in an unfamiliar shape, the `?` absorbs the key going away. With both in place
    // nothing below can fail a decode, which is the whole point of listing them here.
    //
    // Note lengthSeconds is the microformat copy. The duration callers receive is parsed from
    // videoDetails.lengthSeconds, which is required, so this one genuinely is unread.
    let title: RenderedText?
    let description: RenderedText?
    let lengthSeconds: String?
    let externalChannelId: String?
    let ownerChannelName: String?
    let ownerProfileUrl: String?
}

/// Text that YouTube renders either as `{"runs":[{"text":"..."}]}` or `{"simpleText":"..."}`.
///
/// Which one appears varies by field and changes over time, so both are accepted, and any other
/// shape decodes to a nil `text` rather than throwing. That leniency is deliberate but narrow: it
/// belongs to fields nothing depends on. Fields the parser reads stay strict — bar the one case
/// YouTube is known to omit, `VideoDetails.viewCount` — so a schema change that matters still
/// surfaces as `videoInfoParseError` instead of quietly vanishing.
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
    /// Read, and still optional: YouTube publishes no view count for a members-only video, so the
    /// key is legitimately absent from a payload whose every other field is complete.
    ///
    /// This is the exception the comment above `PlayerMicroformat` points at. Required-ness there is
    /// a tripwire for "the parser no longer understands this payload", and an absent view count
    /// means nothing of the kind. Held required, one missing count threw away the title,
    /// description, channel, duration and thumbnails of every members-only video — and bought
    /// nothing, because the public `VideoInfo.viewCount` is already `Int?`, so callers were handling
    /// absence regardless. The loud signal for a video that really is gone now comes from
    /// `PlayabilityStatus`, which can tell a deleted video apart from a schema change.
    let viewCount: String?
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

// MARK: - Playability

/// Wraps `playabilityStatus` so it can be read from a payload that carries nothing else.
///
/// A deleted video's player response has no `videoDetails`, no `microformat` and no `captions` — the
/// only keys are `playabilityStatus` plus tracking. Decoding `VideoResponse` against that reports a
/// missing `videoDetails`, which reads as a YouTube schema change and is the opposite of the truth.
struct PlayabilityResponse: Decodable {
    let playabilityStatus: PlayabilityStatus
}

/// Why YouTube will or will not play a video.
///
/// Read only after every blob has failed to decode. A non-OK status does not by itself mean there is
/// nothing to keep: a members-only video is `UNPLAYABLE` and still carries complete metadata, and
/// checking this first would throw that away.
struct PlayabilityStatus: Decodable {
    /// `OK`, or a reason it is not — `ERROR` for a deleted video, `UNPLAYABLE` for members-only,
    /// `LOGIN_REQUIRED` for private. Required, because a status this cannot read says nothing a
    /// caller could act on, and a payload without one is better reported as the parse error it was.
    let status: String

    /// The human-readable explanation, which some statuses omit.
    ///
    /// A bare string in every payload captured so far. Also read through `RenderedText`, because the
    /// microformat title and description already made this exact move from a rendered shape, and a
    /// reason arriving as `{"simpleText":...}` should cost the caller its text, not the whole error.
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)

        if let plain = try? container.decode(String.self, forKey: .reason) {
            reason = plain
        } else {
            reason = (try? container.decode(RenderedText.self, forKey: .reason))?.text
        }
    }
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
