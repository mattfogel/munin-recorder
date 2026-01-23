import Foundation

struct MeetingRecord {
    let folderURL: URL
    let name: String
    let date: Date

    var audioURL: URL {
        folderURL.appendingPathComponent("audio.m4a")
    }

    var transcriptURL: URL {
        folderURL.appendingPathComponent("transcript.md")
    }

    var summaryURL: URL {
        folderURL.appendingPathComponent("summary.md")
    }

    var wavURL: URL {
        folderURL.appendingPathComponent("audio.wav")
    }
}
