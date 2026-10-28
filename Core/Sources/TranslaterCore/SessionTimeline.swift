import Foundation
import Observation
#if canImport(os)
import os
#endif

/// The only thing the UI reads. Receives the Malay and English streams.
@MainActor @Observable
public final class SessionTimeline {
    public private(set) var segments: [Segment]   // sorted by id; ids only increase
    public private(set) var lastTranslatedID = -1
    public let clock: SessionClock
    public let startDate: Date

    public init(clock: SessionClock = .init(), startDate: Date = .now, segments: [Segment] = []) {
        self.clock = clock
        self.startDate = startDate
        self.segments = segments
        lastTranslatedID = segments.last { $0.english != nil }?.id ?? -1
    }

    public func receiveMalay(_ segment: Segment) {
        segments.append(segment)
    }

    public func receiveEnglish(_ segment: Segment) {
        // ponytail: reverse linear scan; translations land on the newest few segments.
        guard let i = segments.lastIndex(where: { $0.id == segment.id }) else { return }
        segments[i].english = segment.english
        lastTranslatedID = max(lastTranslatedID, segment.id)
    }

    /// Still in flight. A segment the translator skipped (older than the last
    /// translated one) is not pending; it just stays Malay-only.
    public func isTranslationPending(_ segment: Segment) -> Bool {
        segment.english == nil && segment.id > lastTranslatedID
    }

    /// Latest segment that has started by `time`.
    public func activeSegment(at time: Double) -> Segment? {
        segments.last { $0.startTime <= time }
    }

    /// Runs both pipelines until the recorder finishes or the calling task is cancelled.
    /// `record` pushes Malay utterances into the continuation it's given and returns when done.
    /// `translateAll`: for files, where nobody is waiting live, every line is translated instead of
    /// dropping to the newest.
    public func run(
        record: @escaping @Sendable (AsyncStream<Utterance>.Continuation) async throws -> Void,
        translator: TranslatorActor,
        translateAll: Bool = false
    ) async throws {
        let (malay, malayOut) = AsyncStream.makeStream(of: Utterance.self)
        // Bounded on purpose: when translation falls behind, the oldest waiting
        // segments are dropped so the translator always works on the newest speech.
        let (toTranslate, translateIn) = AsyncStream.makeStream(
            of: Utterance.self, bufferingPolicy: translateAll ? .unbounded : .bufferingNewest(TranslatorActor.backlog))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { malayOut.finish() }
                try await record(malayOut)
            }
            group.addTask { @MainActor in
                for await utterance in malay {
                    self.receiveMalay(utterance.segment)
                    translateIn.yield(utterance)   // never suspends
                }
                translateIn.finish()
            }
            group.addTask {
                await translator.run(toTranslate) { english in
                    await self.receiveEnglish(english)
                }
            }
            try await group.waitForAll()
        }
    }
}

/// Owns the MT model. A slow model drops segments; it never blocks the recorder.
public actor TranslatorActor {
    public static let backlog = 2

    private let model: any MalayEnglishModel
    private var lastHeavyRun: ContinuousClock.Instant?
    #if canImport(os)
    private let signposter = OSSignposter(subsystem: "Translater", category: .pointsOfInterest)
    #endif

    public init(model: any MalayEnglishModel) { self.model = model }

    func run(_ input: AsyncStream<Utterance>, emit: @Sendable (Segment) async -> Void) async {
        for await utterance in input {
            var segment = utterance.segment
            // Nothing to translate in unclear audio or a bare "♪" music line.
            guard !segment.isUnclear, segment.malay.contains(where: \.isLetter) else { continue }
            // Already English: shown once, never sent to a model.
            if segment.otherLanguage == "en" {
                segment.english = segment.malay
                await emit(segment)
                continue
            }
            #if os(iOS) || os(macOS)
            // A heavy model on a hot device is rationed so recognition keeps real-time pace: at "serious"
            // one line per 8 s, at "critical" none. Skipping everything at "serious" left a warm iPad
            // (it sits there for a whole session after earlier runs, and while charging) with no English.
            // Light models always run.
            let thermal = ProcessInfo.processInfo.thermalState
            let rationed = thermal == .critical
                || (thermal == .serious && lastHeavyRun.map { $0.duration(to: .now) < .seconds(8) } == true)
            if model.isHeavy, rationed {
                log("segment \(segment.id): skipped, device hot (thermal state \(thermal.rawValue))")
                await emit(segment)   // english stays nil; clears the "translating…" placeholder
                continue
            }
            #endif
            if model.isHeavy { lastHeavyRun = .now }
            #if canImport(os)
            let state = signposter.beginInterval("translate", id: signposter.makeSignpostID(), "segment \(segment.id)")
            defer { signposter.endInterval("translate", state) }
            #endif
            // A failed segment stays Malay-only rather than stopping the session. Emitting it anyway
            // clears its "translating…" placeholder; before, failures left it showing forever.
            do {
                segment.english = try await model.translate(utterance)
                log("segment \(segment.id): \(segment.english ?? "")")
            } catch {
                log("segment \(segment.id): failed: \(String(describing: error))")
            }
            await emit(segment)
        }
    }

    private func log(_ message: String) {
        #if canImport(os)
        Logger(subsystem: "Translater", category: "translator").notice("translator \(message, privacy: .public)")
        #endif
    }
}

/// The translation model plugs in here. Gets the text and the audio; use whichever it needs.
public protocol MalayEnglishModel: Sendable {
    /// A second large model on the device: paused while it's hot.
    var isHeavy: Bool { get }
    func translate(_ utterance: Utterance) async throws -> String
}

extension MalayEnglishModel {
    public var isHeavy: Bool { false }
}
