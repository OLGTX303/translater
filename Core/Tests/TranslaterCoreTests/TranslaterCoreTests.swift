import Foundation
import Testing
@testable import TranslaterCore

let sample: [Segment] = [
    Segment(id: 0, startTime: 0.48, endTime: 2.915, malay: "Selamat pagi semua", english: "Good morning everyone",
            words: [Word(text: "Selamat", start: 0.48, end: 1.0),
                    Word(text: "pagi", start: 1.12, end: 1.6),
                    Word(text: "semua", start: 1.7, end: 2.915)]),
    Segment(id: 1, startTime: 3.2, endTime: 3.9, malay: "", isUnclear: true),
    Segment(id: 2, startTime: 3661.007, endTime: 3665.5, malay: "Terima kasih", english: nil, isLowConfidence: true),
    Segment(id: 3, startTime: 3666, endTime: 3667.25, malay: "See you tomorrow", english: "See you tomorrow", otherLanguage: "en"),
]

/// Pulls every "a --> b" cue time and every <hh:mm:ss.mmm> word tag back out as seconds.
func parse(_ text: String) -> (cues: [(Double, Double)], words: [Double]) {
    func seconds(_ t: Substring) -> Double {
        let p = t.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        return Double(p[0])! * 3600 + Double(p[1])! * 60 + Double(p[2])!
    }
    var cues: [(Double, Double)] = [], words: [Double] = []
    for line in text.split(separator: "\n") {
        if line.contains("-->") {
            let parts = line.components(separatedBy: " --> ")
            cues.append((seconds(Substring(parts[0])), seconds(Substring(parts[1]))))
        } else {
            for tag in line.components(separatedBy: "<").dropFirst() where tag.first?.isNumber == true {
                words.append(seconds(Substring(tag.prefix { $0 != ">" })))
            }
        }
    }
    return (cues, words)
}

@Test(arguments: SubtitleFormat.allCases, [false, true])
func roundTrip(format: SubtitleFormat, bilingual: Bool) {
    let text = SubtitleExport.render(sample, as: format, bilingual: bilingual)
    let parsed = parse(text)

    #expect(parsed.cues.count == sample.count)
    for (cue, s) in zip(parsed.cues, sample) {
        #expect(abs(cue.0 - s.startTime) < 0.0005)
        #expect(abs(cue.1 - s.endTime) < 0.0005)
    }
    #expect(parsed.words == (format == .vtt ? [0.48, 1.12, 1.7] : []))
    #expect(text.contains("[unclear]"))
    #expect(text.contains("[other language: en] See you tomorrow"))
    #expect(text.contains("Good morning everyone") == bilingual)
    #expect(text.hasPrefix("WEBVTT") == (format == .vtt))
    #expect(text.contains("01:01:01" + (format == .srt ? ",007" : ".007")))
}

@Test func writesBothTracks() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let urls = try SubtitleExport.write(sample, sessionDate: Date(timeIntervalSince1970: 0),
                                        format: .srt, bilingual: true, to: dir)
    #expect(urls.map(\.pathExtension) == ["srt", "srt"])
    #expect(try String(contentsOf: urls[1], encoding: .utf8).contains("Good morning everyone"))
}

struct SlowModel: MalayEnglishModel {
    func translate(_ utterance: Utterance) async throws -> String {
        try await Task.sleep(for: .milliseconds(500))
        return "EN " + utterance.segment.malay
    }
}

/// A slow translator must not delay Malay segments reaching the timeline,
/// and must drop to the newest segments instead of queueing all of them.
@Test @MainActor func slowTranslationDoesNotBlockRecorder() async throws {
    let timeline = SessionTimeline()
    let latencies = LatencyBox()

    try await timeline.run(record: { out in
        for id in 0..<5 {
            let sent = ContinuousClock.now
            out.yield(Utterance(segment: Segment(id: id, startTime: Double(id), endTime: Double(id) + 0.9, malay: "ayat \(id)")))
            while await timeline.segments.count <= id { await Task.yield() }
            await latencies.add(sent.duration(to: .now))
            try await Task.sleep(for: .milliseconds(20))
        }
    }, translator: TranslatorActor(model: SlowModel()))

    #expect(await latencies.max < .milliseconds(100))
    // 0 was in flight; 1 and 2 were pushed out of the 2-slot backlog by 3 and 4.
    #expect(timeline.segments.map(\.english) == ["EN ayat 0", nil, nil, "EN ayat 3", "EN ayat 4"])
    #expect(!timeline.isTranslationPending(timeline.segments[1]))
}

@Test @MainActor func cancellingStopsBothPipelines() async {
    let timeline = SessionTimeline()
    let session = Task {
        try await timeline.run(record: { out in
            var id = 0
            while true {
                out.yield(Utterance(segment: Segment(id: id, startTime: 0, endTime: 1, malay: "x")))
                id += 1
                try await Task.sleep(for: .milliseconds(10))
            }
        }, translator: TranslatorActor(model: SlowModel()))
    }
    try? await Task.sleep(for: .milliseconds(100))
    session.cancel()
    _ = await session.result   // hangs here if either pipeline ignores cancellation
    #expect(timeline.segments.count > 0)
}

actor LatencyBox {
    var max: Duration = .zero
    func add(_ d: Duration) { max = Swift.max(max, d) }
}
