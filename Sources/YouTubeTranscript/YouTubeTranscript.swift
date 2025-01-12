import ArgumentParser
import Foundation
import YouTubeTranscriptKit

@main
struct YTT: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "A utility for downloading YouTube video transcripts",
        version: "1.0.0",
        subcommands: [Transcribe.self, Info.self, Activity.self]
    )
}

struct Transcribe: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Download the transcript for a YouTube video"
    )

    @Argument(help: "YouTube video URL or ID")
    var input: String

    mutating func run() async throws {
        let transcript: [TranscriptMoment]

        if input.contains("youtube.com") || input.contains("youtu.be"),
           let url = URL(string: input) {
            transcript = try await YouTubeTranscriptKit.getTranscript(url: url)
        } else {
            transcript = try await YouTubeTranscriptKit.getTranscript(videoID: input)
        }

        print(transcript)
    }
}

struct Info: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Get information about a YouTube video"
    )

    @Argument(help: "YouTube video URL or ID")
    var input: String

    @Flag(name: .long, help: "Include transcript in the output")
    var includeTranscript = false

    mutating func run() async throws {
        let info: VideoInfo

        if input.contains("youtube.com") || input.contains("youtu.be"),
           let url = URL(string: input) {
            info = try await YouTubeTranscriptKit.getVideoInfo(url: url, includeTranscript: includeTranscript)
        } else {
            info = try await YouTubeTranscriptKit.getVideoInfo(videoID: input, includeTranscript: includeTranscript)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(info)
        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }
}

struct Activity: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "activity",
        abstract: "Parse YouTube activity history from Google Takeout's MyActivity.html file (found at Takeout/My Activity/YouTube/MyActivity.html in the zip)"
    )

    @Argument(help: "Path to the activity file")
    var path: String

    mutating func run() async throws {
        let fileURL: URL
        if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path)
        } else {
            let currentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            fileURL = currentURL.appendingPathComponent(path)
        }

        let activities = try await YouTubeTranscriptKit.getActivity(fileURL: fileURL)
        print("Found \(activities.count) activities")

        // Print first few activities as sample
        for (index, activity) in activities.prefix(3).enumerated() {
            print("\nActivity \(index + 1):")
            print("Action: \(activity.action.rawValue)")
            switch activity.link {
            case .video(let id):
                print("Type: Video")
                print("ID: \(id)")
            case .post(let id):
                print("Type: Post")
                print("ID: \(id)")
            case .channel(let id):
                print("Type: Channel")
                print("ID: \(id)")
            case .playlist(let id):
                print("Type: Playlist")
                print("ID: \(id)")
            case .search(let query):
                print("Type: Search")
                print("Query: \(query)")
            }
            print("URL: \(activity.link.url)")
            print("Time: \(activity.timestamp)")
        }
    }
}
