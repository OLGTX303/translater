import AVFoundation
import os
import TranslaterCore
import WhisperKit

/// Mic → VAD → WhisperKit. Knows nothing about translation, so it can't wait on it.
actor RecorderActor {
    static let sampleRate = 16_000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    // ponytail: fixed tuning; expose if real rooms need it.
    private let silenceToCut = 7_200     // 0.45 s of silence ends a segment (fast talkers pause briefly)
    private let maxSegment = 240_000     // 15 s without a pause: cut at the quietest moment instead
    private let preRoll = 4_800          // keep 0.3 s before speech starts
    private let minSegment = 48_000      // under 3 s, wait for a longer pause: music dips made 1 s clips
    private let longSilence = 24_000     // 1.5 s of silence cuts even a short segment
    // Speech = RMS this many times above the room's noise floor (and above a hard minimum).
    // Calibration knobs: raise speechRatio in noisy rooms, lower minSpeechRMS for quiet mics.
    private let speechRatio: Float = 3
    private let minSpeechRMS: Float = 0.003
    private let maxHeld = 160_000        // an unfinished sentence is held back for at most 10 s of audio

    private let whisper: WhisperKit
    private let clock: SessionClock
    private let rawAudioURL: URL?
    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "Translater", category: "recorder")
    private let signposter = OSSignposter(subsystem: "Translater", category: .pointsOfInterest)
    private var audioIn: AsyncStream<[Float]>.Continuation?
    private let gate = SpeechGate(format: RecorderActor.format)
    /// Names and places fed to Whisper as its prompt. (Feeding back the previous text as well was
    /// measured on the 200 wpm clip: WER 3.6% → 4.3% and it dropped the final sentence, so it's out.)
    private let customWords: String
    private let language: SpokenLanguage
    /// `--plain-asr` turns off held-back sentences, sentence lines and the prompt (A/B runs of the speed test).
    private let plain = CommandLine.arguments.contains("--plain-asr")
    /// Session time of the first captured sample; replay adds it to the audio file's position.
    private(set) var audioOrigin = 0.0

    /// `customWords`: names and places to steer spelling ("Lembah Klang, Putrajaya").
    init(model: String, clock: SessionClock, rawAudioURL: URL?, customWords: String = "",
         language: SpokenLanguage = .malay) async throws {
        whisper = try await WhisperKit(ModelStore.config(model))
        self.clock = clock
        self.rawAudioURL = rawAudioURL
        self.customWords = customWords.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
    }

    /// Ends capture; `run` transcribes what's left and returns.
    func finish() { audioIn?.finish() }

    func run(emit: AsyncStream<Utterance>.Continuation) async throws {
        // .default keeps the mic's automatic gain; .measurement left speech too quiet to detect.
        try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        // Unbounded: mic audio is never dropped. Whisper runs faster than real time, so it drains.
        let (audio, audioIn) = AsyncStream.makeStream(of: [Float].self)
        self.audioIn = audioIn
        let file = try Self.startCapture(engine, recordingTo: rawAudioURL, into: audioIn)
        defer {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            // AAC needs finalising or the .m4a won't open; before iOS 18 releasing the file does it.
            if #available(iOS 18.0, *) { file?.close() }
        }
        try await process(audio, emit: emit)
    }

    /// The segmenting loop. Fed by the mic, or by the speed test playing a clip at real-time pace.
    func process(_ audio: AsyncStream<[Float]>, emit: AsyncStream<Utterance>.Continuation) async throws {
        var pending: [Float] = []
        var pendingStart = 0      // absolute sample index of pending[0]
        var lastSpeech: Int?      // absolute sample index at the last voiced window
        var nextID = 0
        var noiseFloor: Float?
        var lastLevelLog = 0
        var heldAt: Int?          // sample index when an unfinished sentence was held back

        /// Transcribe pending[..<cut] and emit it. With `hold`, an unfinished last sentence is kept in
        /// `pending` and re-read together with the audio that follows, instead of being cut in half.
        func commit(upTo cut: Int, hold: Bool) async throws {
            // Short bursts (under 3 s) need to be mostly voice: that's where Whisper invented
            // "Terima kasih", "Eh?" and "Bikini Bikini" in a class recording.
            let needed = cut < 48_000 ? 0.5 : 0.25
            if !plain, let heard = gate.voicedShare(from: pendingStart, to: pendingStart + cut), heard.share < needed {
                // Not speech or singing (noise, room sound, instruments): Whisper would only invent text.
                log.notice("gate: skipped \(Double(cut) / Self.sampleRate, format: .fixed(precision: 1))s, \(Int(heard.share * 100))% voiced, mostly \(heard.top, privacy: .public)")
                pending.removeFirst(cut)
                pendingStart += cut
                heldAt = nil
                if pending.isEmpty { lastSpeech = nil }
                return
            }
            let (utterances, consumed) = try await transcribe(Array(pending[..<cut]), startSample: pendingStart,
                                                              firstID: nextID, holdUnfinished: hold && !plain)
            utterances.forEach { emit.yield($0) }
            nextID += utterances.count
            pending.removeFirst(consumed)
            pendingStart += consumed
            heldAt = consumed < cut ? pendingStart + pending.count : nil
            if pending.isEmpty || heldAt != nil { lastSpeech = nil }
        }

        for await chunk in audio {
            let rms = AudioProcessor.calculateAverageEnergy(of: chunk)
            if noiseFloor == nil {
                audioOrigin = clock.now() - Double(chunk.count) / Self.sampleRate
                noiseFloor = rms
            }
            // Floor drops at once to quieter audio and creeps up slowly, so speech doesn't raise it.
            noiseFloor = min(rms, noiseFloor! + (rms - noiseFloor!) * 0.002)
            pending += chunk
            gate.feed(chunk, format: Self.format)
            let end = pendingStart + pending.count
            if rms > max(minSpeechRMS, noiseFloor! * speechRatio) { lastSpeech = end }
            if end - lastLevelLog >= 16_000 {
                lastLevelLog = end
                let floor = noiseFloor!
                let speech = lastSpeechDescription(lastSpeech, end)
                log.notice("level rms=\(rms, format: .fixed(precision: 4)) floor=\(floor, format: .fixed(precision: 4)) lastSpeech=\(speech, privacy: .public)")
            }

            guard let speech = lastSpeech else {
                if let held = heldAt {
                    // The speaker stopped after an unfinished sentence: commit it after 1.5 s of quiet.
                    if end - held >= longSilence { try await commit(upTo: pending.count, hold: false) }
                    continue
                }
                if pending.count > preRoll {
                    pending.removeFirst(pending.count - preRoll)
                    pendingStart = end - preRoll
                }
                continue
            }
            let silence = end - speech
            let pause = silence >= silenceToCut && (pending.count >= minSegment || silence >= longSilence)
            guard pause || pending.count >= maxSegment else { continue }
            // Nonstop speech: cut at the quietest 0.1 s of the last 3 s so no word is split,
            // and keep the rest for the next segment.
            // A forced cut never holds back, so nonstop speech always makes progress.
            if pause {
                try await commit(upTo: pending.count, hold: true)
            } else {
                try await commit(upTo: Self.quietestPoint(in: pending, lookback: 48_000), hold: false)
            }
        }
        log.notice("audio ended: pending \(pending.count) samples, held \(heldAt != nil), speech \(lastSpeech != nil)")
        if lastSpeech != nil || heldAt != nil, !pending.isEmpty, !Task.isCancelled {
            try await commit(upTo: pending.count, hold: false)
        }
    }

    static func quietestPoint(in samples: [Float], lookback: Int) -> Int {
        let frame = 1_600
        let starts = stride(from: max(0, samples.count - lookback), to: samples.count - frame, by: frame / 2)
        let quietest = starts.min {
            AudioProcessor.calculateAverageEnergy(of: Array(samples[$0..<$0 + frame]))
                < AudioProcessor.calculateAverageEnergy(of: Array(samples[$1..<$1 + frame]))
        }
        return quietest.map { $0 + frame / 2 } ?? samples.count
    }

    /// One cut of audio → its finished segments, and how many samples they used. With `holdUnfinished`,
    /// a last segment that doesn't end a sentence is left out (`consumed` stops where it starts).
    func transcribe(_ samples: [Float], startSample: Int, firstID: Int,
                    holdUnfinished: Bool = false) async throws -> (utterances: [Utterance], consumed: Int) {
        let started = ContinuousClock.now
        let state = signposter.beginInterval("transcribe", id: signposter.makeSignpostID(), "\(samples.count) samples")
        maxTokens = min(224, 16 + samples.count * 10 / 16_000)
        let (results, detected, spoken) = try await recognise(samples)
        let isMalay = spoken == "ms"
        let language = spoken
        signposter.endInterval("transcribe", state)
        let audioSeconds = Double(samples.count) / Self.sampleRate
        let took = started.duration(to: .now) / .seconds(1)
        log.notice("whisper [\(detected, privacy: .public)→\(language, privacy: .public)] \(audioSeconds, format: .fixed(precision: 1))s audio in \(took, format: .fixed(precision: 2))s (RTF \(took / audioSeconds, format: .fixed(precision: 2))): \"\(results.map(\.text).joined(), privacy: .public)\"")

        let base = audioOrigin + Double(startSample) / Self.sampleRate
        let duration = Float(samples.count) / Float(Self.sampleRate)
        // Whisper sometimes reports times past the audio it was given (its 30 s window end); one line
        // landed 22 s in the future. Clamp every line to the chunk.
        var lines = sentenceLines(results.flatMap(\.segments)).map { line in
            var line = line
            line.start = min(max(0, line.start), duration)
            line.end = min(max(line.start, line.end), duration)
            return line
        }
        var consumed = samples.count
        if holdUnfinished, let last = lines.last, !Self.endsSentence(last.text),
           samples.count - Self.sampleIndex(last.start, in: samples) < maxHeld {
            consumed = Self.sampleIndex(last.start, in: samples)
            lines.removeLast()
            log.notice("holding unfinished: \(last.text, privacy: .public)")
        }
        var utterances: [Utterance] = []
        var previous = ""
        for line in lines {
            // "[MUSIC PLAYING]", "(upbeat music)", "*Lirik*", "[음악]": Whisper's sound labels, not words.
            let raw = Self.isSoundLabel(line.text) ? "♪" : line.text
            let text = Self.removingOutro(raw)
            // Only an invented outro (Whisper's guess for silence or noise): not a line at all.
            if text.isEmpty && !raw.isEmpty { continue }
            if !plain, let why = Self.inventedReason(text, previous: previous, alone: lines.count == 1) {
                log.notice("dropped (\(why, privacy: .public)): \(text, privacy: .public)")
                continue
            }
            previous = text
            // Whisper's timestamps can run past the chunk (or come back reversed); building that
            // range unclamped crashed the app on the final flush after Stop.
            let lower = Self.sampleIndex(line.start, in: samples)
            let audioRange = lower..<max(lower, Self.sampleIndex(line.end, in: samples))
            let unclear = text.isEmpty
                || line.parents.contains { $0.noSpeechProb > 0.6 || $0.compressionRatio > 2.4 }
                || line.parents.contains { Self.isLikelyHallucination(text, $0) }
            // A run of unclear lines ("[unclear] we," "[unclear] but," "[unclear] I,") is one stretch.
            if unclear, let last = utterances.last, last.segment.isUnclear {
                utterances[utterances.count - 1].segment.endTime = base + Double(line.end)
                continue
            }
            utterances.append(Utterance(
                segment: Segment(
                    id: firstID + utterances.count,
                    startTime: base + Double(line.start),
                    endTime: base + Double(line.end),
                    malay: text,
                    isLowConfidence: line.parents.contains { $0.avgLogprob < -0.8 },
                    isUnclear: unclear,
                    otherLanguage: isMalay ? nil : language,
                    // Word timings only when the words still match the text (an outro wasn't cut off).
                    words: text != raw ? [] : line.words.map {
                        Word(text: $0.word.trimmingCharacters(in: .whitespaces),
                             start: base + Double($0.start), end: base + Double($0.end))
                    }
                ),
                audio: audioRange.isEmpty ? samples : Array(samples[audioRange])
            ))
        }
        // End of this audio → its segments emitted. If this keeps growing, we're falling behind the speaker.
        let latency = clock.now() - base - Double(samples.count) / Self.sampleRate
        signposter.emitEvent("recorderLatency", "\(latency, format: .fixed(precision: 3)) s")
        log.notice("recorderLatency \(latency, format: .fixed(precision: 2))s")
        return (utterances, consumed)
    }

    struct Line {
        var text = ""
        var start: Float = 0
        var end: Float = 0
        var words: [WordTiming] = []
        var parents: [TranscriptionSegment] = []
    }

    /// Whisper's segments follow its decoding windows, not sentences. Rebuild lines at sentence ends
    /// from the word timings: pieces of one sentence are joined, a segment holding two sentences is
    /// split, each line with exact start/end times. Sound labels, unclear audio and segments without
    /// word timings stay as Whisper gave them. `--plain-asr` keeps Whisper's segments (A/B runs).
    private func sentenceLines(_ segments: [TranscriptionSegment]) -> [Line] {
        var lines: [Line] = []
        var open = Line()
        func close() {
            guard let first = open.words.first, let last = open.words.last else { return }
            open.text = open.words.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            open.start = first.start
            open.end = last.end
            lines.append(open)
            open = Line()
        }
        for s in segments {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = s.words ?? []
            guard !plain, !words.isEmpty, !Self.isSoundLabel(text), s.noSpeechProb <= 0.6, s.compressionRatio <= 2.4 else {
                close()
                lines.append(Line(text: text, start: s.start, end: s.end, words: words, parents: [s]))
                continue
            }
            for word in words {
                open.words.append(word)
                if open.parents.last != s { open.parents.append(s) }
                if Self.endsSentence(word.word) { close() }
            }
        }
        close()
        return lines
    }

    static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.last.map { ".?!…♪)]".contains($0) } == true
    }

    /// Custom words as Whisper prompt tokens.
    private func promptTokens() -> [Int]? {
        guard !plain, !customWords.isEmpty, let tokenizer = whisper.tokenizer else { return nil }
        return tokenizer.encode(text: " " + customWords).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }

    static let malayCodes: Set<String> = ["ms", "id"]
    /// Auto mode keeps Malay and English; anything else detected is noise and dropped.
    static let autoLanguages: Set<String> = ["ms", "en"]

    /// Whisper's reading of one cut, the language it detected, and the language the text is in.
    private func recognise(_ samples: [Float]) async throws -> ([TranscriptionResult], String, String) {
        switch language {
        case .english:
            // One known language: no guessing, no second-guessing. Re-reading English as Malay on
            // near-ties is what turned an English lecture into Malay-shaped nonsense.
            return (try await whisper.transcribe(audioArray: samples, decodeOptions: options(language: "en")), "en", "en")
        case .auto:
            // Whisper's own detection, from the same encoder pass it transcribes with. Only "Indonesian"
            // is re-read as Malay: it's Whisper's usual label for Malay speech. Every other language
            // (Russian, Japanese, Spanish… seen on noise) is dropped as noise.
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options(language: nil))
            let detected = results.first?.language ?? "en"
            if detected == "id" {
                return (try await whisper.transcribe(audioArray: samples, decodeOptions: options(language: "ms")), detected, "ms")
            }
            return (Self.autoLanguages.contains(detected) ? results : [], detected, detected)
        case .malay:
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options(language: nil))
            let detected = results.first?.language ?? "ms"
            guard detected != "ms" else { return (results, detected, "ms") }
            // Whisper often calls Malay Indonesian, and music got jw/km/ko. Re-read it as Malay and keep
            // whichever reading Whisper is more confident in (Malay wins near-ties). The second pass
            // only happens for audio that wasn't detected as Malay.
            let malay = try await whisper.transcribe(audioArray: samples, decodeOptions: options(language: "ms"))
            // Only English may stand against Malay here; any other detected language is a misreading.
            if detected != "en" || Self.confidence(malay) >= Self.confidence(results) - 0.15 {
                return (malay, detected, "ms")
            }
            return (results, detected, detected)
        }
    }

    /// Tokens Whisper may write for the current cut: 10 per second of audio (fast Malay at 200 wpm
    /// needs about 6) plus headroom. Without it, a confused 2 s cut looped to 224 tokens per pass and
    /// took 73 s.
    private var maxTokens = 224

    // One fallback instead of five: on noise every extra pass only produced more invented text, and
    // a looping cut cost 43 s with two.
    private func options(language: String?) -> DecodingOptions {
        DecodingOptions(language: language, temperatureFallbackCount: 1, sampleLength: maxTokens,
                        detectLanguage: language == nil, skipSpecialTokens: true, wordTimestamps: true,
                        promptTokens: promptTokens())
    }

    /// Mean log-probability over a transcription's segments; higher is more confident.
    static func confidence(_ results: [TranscriptionResult]) -> Float {
        let segments = results.flatMap(\.segments)
        return segments.isEmpty ? -.infinity : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
    }
    // Phrases Whisper invents for music, noise or silence (it learned them from video outros).
    static let hallucinations: Set<String> = ["terima kasih", "thank you"]
    // Video outros Whisper tacks on with full confidence, even onto real sentences.
    // Live speech essentially never says them, so they're always cut from the end.
    static let outros = [
        "terima kasih kerana menonton", "terima kasih telah menonton", "jangan lupa langgan", "sila langgan",
        "thank you for watching", "thanks for watching",
    ]

    static func removingOutro(_ text: String) -> String {
        var text = text
        for outro in outros {
            let trimmed = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if let range = trimmed.range(of: outro, options: [.caseInsensitive, .anchored, .backwards]) {
                text = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    // Lines Whisper invents from its training videos. Dropped wherever they appear, at any confidence:
    // a class doesn't say "subtitles by" or "thanks for watching".
    static let inventedPhrases = [
        "thank you for watching", "thanks for watching", "thank you so much for watching",
        "subtitles by", "subtitle by", "captions by", "transcribed by", "translated by",
        "please subscribe", "like and subscribe", "don't forget to subscribe", "amara.org",
        "terima kasih kerana menonton", "terima kasih telah menonton", "terima kasih kerana mendengar",
        "jangan lupa langgan", "jangan lupa subscribe", "sila langgan", "sari kata oleh", "terjemahan oleh",
        "see you next time", "see you in the next video", "see you in the next one",
        ".com", ".net", ".org", "www.", "/subs", "http",
    ]
    // Misspelt outros ("Terima kasih kerena menerima video ini", "keranya menonton"): thanks plus a
    // word only video outros use.
    static let outroWords = ["menonton", "tonton", "video", "subscribe", "langgan", "watching"]
    // Thanks on its own, as Whisper writes it for a cough or a door: dropped when it's all a chunk held.
    static let bareThanks: Set<String> = ["terima kasih", "terimaku", "terimu kasih", "thank you", "thanks",
                                          "terima kasih banyak", "thank you very much", "okay terima kasih"]

    /// Why a line is Whisper's invention rather than speech, or nil if it looks real.
    static func inventedReason(_ text: String, previous: String, alone: Bool) -> String? {
        let lower = text.lowercased()
        if inventedPhrases.contains(where: lower.contains) { return "stock phrase" }
        if (lower.contains("terima") || lower.contains("thank")), outroWords.contains(where: lower.contains) {
            return "outro"
        }
        let bare = lower.filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        if alone, bareThanks.contains(bare) { return "bare thanks" }
        // "- -", "...", "♪ ♪ ♪": nothing said. A single ♪ stays as the music marker.
        if text != "♪", !text.contains(where: \.isLetter) { return "no words" }
        // "I can't believe it. I can't believe it.": the same sentence again.
        let normalized = lower.filter { $0.isLetter || $0 == " " }
        if !normalized.isEmpty, normalized == previous.lowercased().filter({ $0.isLetter || $0 == " " }) { return "repeat" }
        // "Thank you. Thank you.", "日本 日本 日本": a few words looping.
        let words = normalized.split(separator: " ")
        if words.count >= 4, Set(words).count * 3 <= words.count { return "loop" }
        return nil
    }

    /// A stock outro phrase is only trusted when Whisper was confident it heard speech.
    /// ponytail: fixed list; a real "terima kasih" said mumbled gets dropped too.
    static func isLikelyHallucination(_ text: String, _ s: TranscriptionSegment) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return hallucinations.contains(normalized) && (s.avgLogprob < -0.5 || s.noSpeechProb > 0.3)
    }

    static func sampleIndex(_ seconds: Float, in samples: [Float]) -> Int {
        guard seconds.isFinite else { return samples.count }
        return min(samples.count, max(0, Int(Double(seconds) * sampleRate)))
    }

    static func isSoundLabel(_ text: String) -> Bool {
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*")]
        return pairs.contains { text.count > 2 && text.first == $0.0 && text.last == $0.1 }
    }

    private func lastSpeechDescription(_ lastSpeech: Int?, _ end: Int) -> String {
        lastSpeech.map { String(format: "%.1fs ago", Double(end - $0) / Self.sampleRate) } ?? "none"
    }

    /// Nonisolated so the tap block (called on an audio thread) isn't treated as actor-isolated.
    /// Whisper gets 16 kHz mono; the recording keeps the mic's own rate as AAC, like Voice Memos.
    private nonisolated static func startCapture(_ engine: AVAudioEngine, recordingTo url: URL?,
                                                 into audioIn: AsyncStream<[Float]>.Continuation) throws -> AVAudioFile? {
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hw, to: format) else { throw RecorderError.unsupportedInput }
        let file = try url.map {
            try AVAudioFile(forWriting: $0, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: hw.sampleRate,
                AVNumberOfChannelsKey: hw.channelCount,
                AVEncoderBitRateKey: 64_000 * Int(hw.channelCount),
            ], commonFormat: hw.commonFormat, interleaved: hw.isInterleaved)
        }
        // Deprecated in the iOS 27 SDK; its throwing replacement is iOS 27+ only and we target 17.
        input.installTap(onBus: 0, bufferSize: 4_096, format: hw) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / hw.sampleRate) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var consumed = false
            converter.convert(to: out, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            // ponytail: AAC encode on the tap thread; move to a queue if it ever causes dropouts.
            try? file?.write(from: buffer)
            audioIn.yield(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
        }
        engine.prepare()
        try engine.start()
        return file
    }
}

enum RecorderError: Error {
    case unsupportedInput
}
