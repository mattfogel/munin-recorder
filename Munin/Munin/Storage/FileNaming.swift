import Foundation

enum FileNaming {
    /// Sanitizes a string for use in filenames
    static func sanitize(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Limit length
        let maxLength = 50
        if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength))
        }

        return sanitized.isEmpty ? "untitled" : sanitized
    }

    /// Generates a folder name for a meeting
    static func meetingFolderName(date: Date, meetingName: String) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmm"
        let timeString = timeFormatter.string(from: date)

        let sanitizedName = sanitize(meetingName)
        return "\(timeString)-\(sanitizedName)"
    }

    /// Generates the date folder name
    static func dateFolderName(date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: date)
    }
}
