import Foundation
import Observation
import WhisperKit

/// Whisper models live in Application Support, downloaded once. That folder survives app updates,
/// so installing a new build no longer pushes 1.5 GB of models to the device each time.
enum ModelStore {
    static let base = URL.applicationSupportDirectory.appending(path: "WhisperModels")

    static func config(_ name: String) async throws -> WhisperKitConfig {
        let folder = try await folder(for: name)
        // tokenizerFolder: WhisperKit fetches the tokenizer there once, then reuses the local copy.
        return WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: base, verbose: false, download: false)
    }

    private static func folder(for name: String) async throws -> URL {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil) { return bundled }
        // The marker holds the folder relative to `base`: the app container's absolute path can change
        // between installs, and a download cut off halfway has no marker, so it's resumed next time.
        let marker = base.appending(path: "\(name).complete")
        if let relative = try? String(contentsOf: marker, encoding: .utf8) {
            return base.appending(path: relative)
        }
        let downloaded = try await WhisperKit.download(variant: name, downloadBase: base) { progress in
            Task { @MainActor in
                ModelDownloads.shared.status = "Downloading model \(Int(progress.fractionCompleted * 100))%"
            }
        }
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true   // 1.5 GB that can always be fetched again
        var folder = base
        try? folder.setResourceValues(noBackup)
        let relative = String(downloaded.path.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try relative.write(to: marker, atomically: true, encoding: .utf8)
        await MainActor.run { ModelDownloads.shared.status = nil }
        return downloaded
    }
}

/// Download progress for the Live screen's title.
@MainActor @Observable
final class ModelDownloads {
    static let shared = ModelDownloads()
    var status: String?
}
