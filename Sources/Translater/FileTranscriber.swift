import Foundation
import os
import TranslaterCore
import WhisperKit

/// Runs a recording (a class, a WhatsApp voice note, a video's audio) through the same pipeline as
/// the mic: same segmenting, held-back sentences and translator, as fast as the device allows.
/// The result is a normal session: subtitles, the audio for replay, and exports.
enum FileTranscriber {
    static let log = Logger(subsystem: "Translater", category: "file")

    /// `onLine` sees each finished line as it lands (for progress). Returns the saved session's JSON URL.
    @MainActor
    static func transcribe(_ source: URL, onLine: @escaping @MainActor (SessionTimeline) -> Void = { _ in }) async throws -> URL {
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: source.path)
        let clock = SessionClock()
        let timeline = SessionTimeline(clock: clock)
        let recorder = try await RecorderActor(
            model: RecognitionChoice.current.model, clock: clock, rawAudioURL: nil,
            customWords: UserDefaults.standard.string(forKey: Pref.customWords) ?? "",
            language: SpokenLanguage.current)
        let translator = try await TranslatorChoice.current.load()
        let started = ContinuousClock.now
        log.notice("file: \(source.lastPathComponent, privacy: .public), \(Double(samples.count) / 16_000, format: .fixed(precision: 0)) s, \(SpokenLanguage.current.rawValue, privacy: .public), \(RecognitionChoice.current.rawValue, privacy: .public)")

        let watcher = Task { @MainActor in
            var seen = 0
            while !Task.isCancelled {
                if timeline.segments.count != seen { seen = timeline.segments.count; onLine(timeline) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await timeline.run(record: { out in
            // The "mic", at full speed: 0.1 s pieces, all at once. The recorder's pauses and cuts are
            // measured in samples, so they behave exactly as they would live.
            let (audio, feed) = AsyncStream.makeStream(of: [Float].self)
            for i in stride(from: 0, to: samples.count, by: 1_600) {
                feed.yield(Array(samples[i..<min(i + 1_600, samples.count)]))
            }
            feed.finish()
            try await recorder.process(audio, emit: out)
        }, translator: TranslatorActor(model: translator), translateAll: true)

        // Save like a live session: the audio for replay, the timeline next to it.
        let audioCopy = SavedSession.url(timeline.startDate, "m4a")
        try? FileManager.default.copyItem(at: source, to: audioCopy)
        let json = SavedSession.url(timeline.startDate, "json")
        let offset = await recorder.audioOrigin
        try JSONEncoder().encode(SavedSession(startDate: timeline.startDate, audioOffset: offset,
                                              segments: timeline.segments)).write(to: json)
        let took = started.duration(to: .now) / .seconds(1)
        log.notice("file done: \(timeline.segments.count) lines in \(took, format: .fixed(precision: 0)) s")
        for segment in timeline.segments {
            log.notice("file line \(segment.id) [\(segment.startTime - offset, format: .fixed(precision: 1))]: \(segment.marker + segment.malay, privacy: .public)")
        }
        return json
    }
}
