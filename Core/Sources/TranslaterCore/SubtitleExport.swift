import Foundation

public enum SubtitleFormat: String, CaseIterable, Sendable {
    case srt, vtt
}

public enum SubtitleExport {
    /// `bilingual`: Malay line then English line per cue. `wordTags`: VTT only, ignored for SRT.
    public static func render(_ segments: [Segment], as format: SubtitleFormat,
                              bilingual: Bool, wordTags: Bool = true) -> String {
        var out = format == .vtt ? "WEBVTT\n\n" : ""
        for (n, s) in segments.enumerated() {
            out += "\(n + 1)\n"
            out += "\(timestamp(s.startTime, format)) --> \(timestamp(s.endTime, format))\n"
            out += malayLine(s, timed: format == .vtt && wordTags) + "\n"
            if bilingual, let english = s.english, !english.isEmpty, english != s.malay { out += english + "\n" }
            out += "\n"
        }
        return out
    }

    /// Writes the Malay track, plus the bilingual track when `bilingual`. Returns the file URLs.
    public static func write(_ segments: [Segment], sessionDate: Date, format: SubtitleFormat,
                             bilingual: Bool, to directory: URL) throws -> [URL] {
        try (bilingual ? [false, true] : [false]).map { both in
            let url = directory.appendingPathComponent(
                "\(stem(sessionDate)) \(both ? "bilingual" : "malay").\(format.rawValue)")
            try render(segments, as: format, bilingual: both).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// "Session 2026-10-27 145000", shared by subtitle, timeline and audio files.
    public static func stem(_ sessionDate: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return "Session " + f.string(from: sessionDate)
    }

    static func malayLine(_ s: Segment, timed: Bool) -> String {
        let text = timed && !s.words.isEmpty
            ? s.words.map { "<\(timestamp($0.start, .vtt))><c>\($0.text.trimmingCharacters(in: .whitespaces))</c>" }
                .joined(separator: " ")
            : s.malay.trimmingCharacters(in: .whitespaces)
        // Whisper's guess for an unclear stretch is unreliable: mark the stretch, don't show the guess.
        return s.isUnclear ? "[unclear]" : s.marker + text
    }

    /// SRT: 00:01:02,345   VTT: 00:01:02.345
    public static func timestamp(_ seconds: Double, _ format: SubtitleFormat) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        let sep = format == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60)
            + sep + String(format: "%03d", ms % 1000)
    }
}
