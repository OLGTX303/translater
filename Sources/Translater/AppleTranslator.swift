import Foundation
import Translation
import TranslaterCore

/// Apple's on-device text translator. Far cheaper than a second Whisper model, since it only
/// sees the recognised text. Needs the language pack installed (Settings has a download button).
/// @unchecked: only TranslatorActor calls it, one segment at a time.
@available(iOS 26.0, *)
final class AppleTranslator: MalayEnglishModel, @unchecked Sendable {
    struct PackMissing: LocalizedError {
        var errorDescription: String? { "Apple's Malay pack isn't downloaded. Settings → Translation → Download." }
    }

    static let english = Locale.Language(identifier: "en")
    private let session: TranslationSession

    init() async throws {
        guard let source = await Self.source(requiring: .installed) else { throw PackMissing() }
        session = TranslationSession(installedSource: source, target: Self.english)
    }

    /// Malay when Apple offers it, otherwise Indonesian, which reads most Malay correctly.
    static func source(requiring status: LanguageAvailability.Status) async -> Locale.Language? {
        for code in ["ms", "id"] {
            let language = Locale.Language(identifier: code)
            let found = await LanguageAvailability().status(from: language, to: english)
            if found == status || (status == .supported && found == .installed) { return language }
        }
        return nil
    }

    func translate(_ utterance: Utterance) async throws -> String {
        let segment = utterance.segment
        if segment.otherLanguage == "en" { return segment.malay }
        // ponytail: other non-Malay languages aren't translated here; Whisper mode handles them.
        guard segment.otherLanguage == nil else { throw PackMissing() }
        return try await session.translate(segment.malay).targetText
    }
}
