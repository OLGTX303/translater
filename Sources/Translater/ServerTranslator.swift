import Foundation
import TranslaterCore

/// Translation on the N100 (NLLB-200 600M behind https://translate.olgtx.com, see Server/).
/// Light on the iPad: one small HTTPS request per line. Falls back to Apple Translate when the
/// server is slow (3 s) or unreachable, so subtitles keep coming on a bad connection.
/// @unchecked: only TranslatorActor calls it, one segment at a time.
final class ServerTranslator: MalayEnglishModel, @unchecked Sendable {
    static let endpoint = URL(string: "https://translate.olgtx.com/translate")!

    private struct Reply: Decodable { let english: String }

    private let fallback: (any MalayEnglishModel)?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    init() async {
        if #available(iOS 26.0, *) { fallback = try? await AppleTranslator() } else { fallback = nil }
    }

    func translate(_ utterance: Utterance) async throws -> String {
        do {
            return try await remote(utterance.segment)
        } catch {
            guard let fallback else { throw error }
            return try await fallback.translate(utterance)
        }
    }

    private func remote(_ segment: Segment) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        // ServerSecret.swift is generated on the build VM from the N100's token and never kept in
        // the project folder; rotate by regenerating it and rebuilding.
        request.setValue("Bearer \(ServerSecret.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": segment.malay, "source": segment.otherLanguage ?? "ms"])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Reply.self, from: data).english
    }
}
