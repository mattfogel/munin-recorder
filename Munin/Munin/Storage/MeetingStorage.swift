import Foundation

final class MeetingStorage {
    let meetingsDirectory: URL

    init() {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        meetingsDirectory = homeDirectory.appendingPathComponent("Meetings")
    }

    func createMeetingFolder(name: String, date: Date = Date()) throws -> MeetingRecord {
        let dateFolderName = FileNaming.dateFolderName(date: date)
        let meetingFolderName = FileNaming.meetingFolderName(date: date, meetingName: name)

        let dateFolder = meetingsDirectory.appendingPathComponent(dateFolderName)
        let meetingFolder = dateFolder.appendingPathComponent(meetingFolderName)

        try FileManager.default.createDirectory(
            at: meetingFolder,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return MeetingRecord(
            folderURL: meetingFolder,
            name: name,
            date: date
        )
    }

    func listMeetings() -> [MeetingRecord] {
        var records: [MeetingRecord] = []

        guard let dateFolders = try? FileManager.default.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return records
        }

        for dateFolder in dateFolders {
            guard let meetingFolders = try? FileManager.default.contentsOfDirectory(
                at: dateFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else {
                continue
            }

            for meetingFolder in meetingFolders {
                let audioFile = meetingFolder.appendingPathComponent("audio.m4a")
                if FileManager.default.fileExists(atPath: audioFile.path) {
                    let record = MeetingRecord(
                        folderURL: meetingFolder,
                        name: meetingFolder.lastPathComponent,
                        date: Date() // Would parse from folder name in production
                    )
                    records.append(record)
                }
            }
        }

        return records
    }
}
