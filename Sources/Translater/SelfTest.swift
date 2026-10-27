import Foundation
import Observation
import os
import TranslaterCore
import WhisperKit

/// Plays a bundled 200 wpm Malay clip into the real recorder at real-time pace, as if it came from
/// the mic, with the translator running, and reports how far behind the speaker the text falls.
/// Run it from Settings, or `xtool launch <bundle-id> -- --selftest` on a freshly started app.
@MainActor @Observable
final class SpeedTest {
    static let shared = SpeedTest()
    static let clipWords = 193   // SelfTest/fast.txt, read at ~202 wpm (57.3 s)

    private(set) var report = ""
    private(set) var running = false
    private let log = Logger(subsystem: "Translater", category: "speedtest")

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            report = "Loading models…"
            log.notice("speedtest args: \(CommandLine.arguments.dropFirst().joined(separator: " "), privacy: .public)")
            let clock = SessionClock()
            let recorder = try await RecorderActor(model: RecognitionChoice.current.model, clock: clock, rawAudioURL: nil)
            let translator = try await TranslatorChoice.current.load()
            guard let url = Bundle.main.url(forResource: "fast200", withExtension: "mp3") else {
                report = "fast200.mp3 is not in this build"
                return
            }
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
            let timeline = SessionTimeline(clock: clock)
            let lags = Lags()
            report = "Playing the 200 wpm clip in real time…"

            try await timeline.run(record: { out in
                let (audio, mic) = AsyncStream.makeStream(of: [Float].self)
                let (heard, heardIn) = AsyncStream.makeStream(of: Utterance.self)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {   // the "mic": 0.1 s pieces on a real-time schedule
                        let start = ContinuousClock.now
                        for (n, i) in stride(from: 0, to: samples.count, by: 1_600).enumerated() {
                            try await Task.sleep(until: start + .milliseconds(100 * (n + 1)), clock: .continuous)
                            mic.yield(Array(samples[i..<min(i + 1_600, samples.count)]))
                        }
                        mic.finish()
                    }
                    group.addTask {
                        defer { heardIn.finish() }
                        try await recorder.process(audio, emit: heardIn)
                    }
                    group.addTask {   // how long after the speaker finished each line did it appear?
                        for await utterance in heard {
                            await lags.add(clock.now() - utterance.segment.endTime)
                            out.yield(utterance)
                        }
                    }
                    try await group.waitForAll()
                }
            }, translator: TranslatorActor(model: translator))

            let all = await lags.values
            let words = timeline.segments.reduce(0) { $0 + $1.malay.split(separator: " ").count }
            let translated = timeline.segments.filter { $0.english != nil }.count
            let keptUp = (all.last ?? .infinity) < 8 && (all.max() ?? .infinity) < 12
            let script = Bundle.main.url(forResource: "fast", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let heard = timeline.segments.map(\.malay).joined(separator: " ")
            let mode = (CommandLine.arguments.contains("--plain-asr") ? "plain" : "hold+sentences")
                + ", \(RecognitionChoice.current.rawValue)"
            report = """
            \(keptUp ? "PASS" : "FAIL"): \(Self.clipWords) words in \(String(format: "%.1f", Double(samples.count) / 16_000)) s
            Heard \(words) words in \(timeline.segments.count) lines, \(translated) translated
            Word error rate (\(mode)): \(String(format: "%.1f", Self.wordErrorRate(heard, script) * 100))%
            Delay behind speaker: max \(String(format: "%.1f", all.max() ?? 0)) s, last \(String(format: "%.1f", all.last ?? 0)) s
            Delays: \(all.map { String(format: "%.1f", $0) }.joined(separator: " "))
            """
            log.notice("speedtest \(self.report, privacy: .public)")
            for segment in timeline.segments {
                log.notice("speedtest line \(segment.id): \(segment.malay, privacy: .public) | \(segment.english ?? "-", privacy: .public)")
            }
        } catch {
            report = "Failed: \(error.localizedDescription)"
            log.error("speedtest failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension SpeedTest {
    /// Word-level edit distance / reference length, ignoring case and punctuation.
    nonisolated static func wordErrorRate(_ hypothesis: String, _ reference: String) -> Double {
        func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        }
        let h = words(hypothesis), r = words(reference)
        guard !r.isEmpty else { return 1 }
        var row = Array(0...h.count)
        for i in 1...r.count {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let current = row[j]
                row[j] = r[i - 1] == h[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return Double(row[h.count]) / Double(r.count)
    }
}

private actor Lags {
    var values: [Double] = []
    func add(_ lag: Double) { values.append(lag) }
}
