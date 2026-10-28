import AVFoundation
import os
import SoundAnalysis

/// Apple's built-in sound classifier running over the incoming 16 kHz audio: how much of a stretch is
/// someone speaking or singing. The loudness detector alone let chairs, air-con, chatter and TV
/// through, and Whisper invents text for anything that isn't speech ("Thank you for watching",
/// "Subtitles by…", Russian, Japanese), slowly. Stretches that aren't voiced never reach Whisper.
/// @unchecked: windows are guarded by the lock; the analyzer is only fed from the recorder actor.
final class SpeechGate: NSObject, SNResultsObserving, @unchecked Sendable {
    // Version 1 classifier labels that mean a human voice saying or singing words.
    static let voiced: Set<String> = ["speech", "shout", "yell", "whispering", "singing", "choir",
                                      "chant", "child_singing", "rapping", "synthetic_singing"]
    // A window counts as voiced when a voice is its top label, or a voice label reaches this
    // confidence. 0.5 alone skipped real classroom speech that the classifier ranked first at ~0.3.
    // ponytail: fixed; tune if quiet speakers get skipped or noisy rooms leak through.
    static let minVoicedConfidence = 0.3

    private let analyzer: SNAudioStreamAnalyzer
    private let lock = NSLock()
    private var windows: [(start: Int, end: Int, voiced: Double, top: String)] = []
    private var position: AVAudioFramePosition = 0
    private let log = Logger(subsystem: "Translater", category: "gate")

    init(format: AVAudioFormat) {
        analyzer = SNAudioStreamAnalyzer(format: format)
        super.init()
        do {
            try analyzer.add(SNClassifySoundRequest(classifierIdentifier: .version1), withObserver: self)
        } catch {
            log.error("sound classifier unavailable, gate open: \(String(describing: error), privacy: .public)")
        }
    }

    /// The same 16 kHz pieces the recorder buffers, in order.
    func feed(_ samples: [Float], format: AVAudioFormat) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        analyzer.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(samples.count)
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let top = result.classifications.first?.identifier ?? "?"
        let voiced = Self.voiced.contains(top) ? 1
            : result.classifications.filter { Self.voiced.contains($0.identifier) }.map(\.confidence).max() ?? 0
        let start = Int(result.timeRange.start.seconds * 16_000)
        let end = Int(CMTimeRangeGetEnd(result.timeRange).seconds * 16_000)
        lock.withLock { windows.append((start, end, voiced, top)) }
    }

    /// Share of classified windows overlapping [start, end) that are voiced; nil when none are in yet.
    /// Also prunes windows that end before `start`, which are never asked about again.
    func voicedShare(from start: Int, to end: Int) -> (share: Double, top: String)? {
        lock.withLock {
            windows.removeAll { $0.end <= start }
            let inside = windows.filter { $0.start < end }
            guard !inside.isEmpty else { return nil }
            let voiced = inside.filter { $0.voiced >= Self.minVoicedConfidence }.count
            // Most common top label, for the log: says what the gate heard instead of speech.
            let top = Dictionary(grouping: inside, by: \.top).max { $0.value.count < $1.value.count }?.key ?? "?"
            return (Double(voiced) / Double(inside.count), top)
        }
    }
}
