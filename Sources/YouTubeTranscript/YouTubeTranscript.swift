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
            fileURL = URL(fileURLWithPath: path).standardizedFileURL
        } else if path.hasPrefix("~") {
            let expandedPath = (path as NSString).expandingTildeInPath
            fileURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        } else {
            let currentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            fileURL = currentURL.appendingPathComponent(path).standardizedFileURL
        }

        do {
            let activities = try await YouTubeTranscriptKit.getActivity(fileURL: fileURL)
            print("Found \(activities.count) activities")

            // Print first few activities as sample
            for (index, activity) in activities.prefix(3).enumerated() {
                print("\nActivity \(index + 1):")
                print("Action: \(activity.action.rawValue)")
                switch activity.link {
                case .video(let id, let title):
                    print("Type: Video")
                    print("ID: \(id)")
                    if let title = title {
                        print("Title: \(title)")
                    }
                case .post(let id, let text):
                    print("Type: Post")
                    print("ID: \(id)")
                    print("Text: \(text)")
                case .channel(let id, let name):
                    print("Type: Channel")
                    print("ID: \(id)")
                    print("Name: \(name)")
                case .playlist(let id, let title):
                    print("Type: Playlist")
                    print("ID: \(id)")
                    print("Title: \(title)")
                case .search(let query):
                    print("Type: Search")
                    print("Query: \(query)")
                case .none:
                    print("Type: None")
                }
                if let url = activity.link.url {
                    print("URL: \(url)")
                }
                print("Time: \(activity.timestamp)")
            }
        } catch YouTubeTranscriptKit.TranscriptError.activityParseError(let block, let reason) {
            print("Failed to parse activity block:")
            print("Reason: \(reason)")
            print("\nBlock content:")
            print(block)
            throw YouTubeTranscriptKit.TranscriptError.activityParseError(block: block, reason: reason)
        }
    }
}
