import Foundation
import os
import TranslaterCore
import WhisperKit

/// Whisper's built-in translate task: the segment's audio, in any language, straight to English.
/// Its own WhisperKit instance, so translating never touches the recorder's model.
/// @unchecked: only TranslatorActor calls it, one segment at a time.
final class WhisperTranslator: MalayEnglishModel, @unchecked Sendable {
    struct NoText: Error {}

    private let whisper: WhisperKit
    let isHeavy = true
    private let log = Logger(subsystem: "Translater", category: "translator")

    /// Turbo models were trained without translation, so this must be a non-turbo model.
    init(model: String) async throws {
        // Neural Engine (WhisperKit's default). The GPU was faster to start but overheated the iPad
        // within a minute of 200 wpm speech.
        whisper = try await WhisperKit(ModelStore.config(model))
    }

    func translate(_ utterance: Utterance) async throws -> String {
        let options = DecodingOptions(task: .translate, language: utterance.segment.otherLanguage ?? "ms",
                                      skipSpecialTokens: true, withoutTimestamps: true)
        let text = try await whisper.transcribe(audioArray: utterance.audio, decodeOptions: options)
            .map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NoText() }
        log.notice("translate \(utterance.segment.id): \(text, privacy: .public)")
        return text
    }
}
