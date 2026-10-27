import Foundation

public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One utterance. The recorder emits it with `english == nil`; the translator
/// re-emits the same id and timestamps with `english` filled in.
public struct Segment: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public var startTime: Double   // seconds from session start
    public var endTime: Double
    public var malay: String
    public var english: String?
    public var isLowConfidence: Bool
    public var isUnclear: Bool
    public var otherLanguage: String?   // Whisper language code when the speech wasn't Malay
    public var words: [Word]       // empty when WhisperKit gave no word timings

    public init(id: Int, startTime: Double, endTime: Double, malay: String, english: String? = nil,
                isLowConfidence: Bool = false, isUnclear: Bool = false, otherLanguage: String? = nil,
                words: [Word] = []) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.malay = malay
        self.english = english
        self.isLowConfidence = isLowConfidence
        self.isUnclear = isUnclear
        self.otherLanguage = otherLanguage
        self.words = words
    }

    /// "[unclear] " / "[other language: en] " / "", shown before the text on screen and in subtitles.
    public var marker: String {
        if isUnclear { return "[unclear] " }
        if let otherLanguage { return "[other language: \(otherLanguage)] " }
        return ""
    }
}

/// A segment plus its audio, for translators that work from speech rather than text.
/// The audio stays out of the timeline; only the translator sees it.
public struct Utterance: Sendable {
    public var segment: Segment
    public var audio: [Float]

    public init(segment: Segment, audio: [Float] = []) {
        self.segment = segment
        self.audio = audio
    }
}

/// The one monotonic clock for a session. Recorder, translator and UI all read it.
public struct SessionClock: Sendable {
    public let origin: ContinuousClock.Instant

    public init(origin: ContinuousClock.Instant = .now) { self.origin = origin }

    public func now() -> Double {
        let d = origin.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }
}
