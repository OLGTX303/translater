import AVFoundation
import SwiftUI
import Translation
import UniformTypeIdentifiers
import _Translation_SwiftUI   // .translationTask; xtool on Linux doesn't apply the SwiftUI+Translation cross-import overlay
import TranslaterCore

@main
struct TranslaterApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                LiveView().tabItem { Label("Live", systemImage: "waveform") }
                SessionsView().tabItem { Label("Sessions", systemImage: "list.bullet") }
                SettingsView().tabItem { Label("Settings", systemImage: "gear") }
            }
            .task {
                // Launched for a test run: run it, then quit so the next `xtool launch` starts fresh.
                if CommandLine.arguments.contains("--selftest") {
                    await SpeedTest.shared.run()
                    try? await Task.sleep(for: .seconds(2))   // let the log flush
                    exit(0)
                }
                // `--transcribe=<file>`: a bundled or Documents file through the pipeline, then quit.
                if let name = CommandLine.arguments.first(where: { $0.hasPrefix("--transcribe=") })?
                    .split(separator: "=", maxSplits: 1).last.map(String.init) {
                    let url = Bundle.main.url(forResource: name, withExtension: nil)
                        ?? URL.documentsDirectory.appending(path: name)
                    do { _ = try await FileTranscriber.transcribe(url) } catch {
                        FileTranscriber.log.error("file failed: \(String(describing: error), privacy: .public)")
                    }
                    try? await Task.sleep(for: .seconds(2))
                    exit(0)
                }
            }
        }
    }
}

enum Pref {
    static let exportFormat = "exportFormat"
    static let bilingual = "exportBilingual"
    static let wordHighlighting = "wordHighlighting"
    static let saveRawAudio = "saveRawAudio"
    static let translator = "translator"
    static let customWords = "customWords"
    static let recognition = "recognition"
    static let spokenLanguage = "spokenLanguage"
}

/// What the speaker speaks. Fixing it is more accurate than detecting it per utterance.
enum SpokenLanguage: String, CaseIterable {
    case malay, english, auto

    var label: String {
        switch self {
        case .malay: "Malay"
        case .english: "English"
        case .auto: "Malay + English"
        }
    }

    /// For the status strip: what's heard → what's shown.
    var route: String {
        switch self {
        case .malay: "MS → EN"
        case .english: "EN"
        case .auto: "MS+EN → EN"
        }
    }

    /// The Settings choice; a `--lang=malay|english|auto` launch argument overrides it (for test runs).
    static var current: SpokenLanguage {
        let override = CommandLine.arguments.first { $0.hasPrefix("--lang=") }?.split(separator: "=").last
        return override.flatMap { Self(rawValue: String($0)) }
            ?? UserDefaults.standard.string(forKey: Pref.spokenLanguage).flatMap(Self.init) ?? .auto
    }
}

/// Settings switch. Apple and Whisper run on the iPad's Neural Engine; Server runs on the N100.
enum TranslatorChoice: String, CaseIterable {
    case server, apple, whisper

    var label: String {
        switch self {
        case .server: "N100 server"
        case .apple: "Apple Translate"
        case .whisper: "Whisper large-v3"
        }
    }

    /// The Settings choice; a `--translator=apple|whisper` launch argument overrides it (for test runs).
    static var current: TranslatorChoice {
        let override = CommandLine.arguments.first { $0.hasPrefix("--translator=") }?.split(separator: "=").last
        return override.flatMap { Self(rawValue: String($0)) }
            ?? UserDefaults.standard.string(forKey: Pref.translator).flatMap(Self.init) ?? .server
    }

    /// Loads only the chosen translator, so the other one costs no memory or heat.
    func load() async throws -> any MalayEnglishModel {
        if self == .server { return await ServerTranslator() }
        if self == .apple, #available(iOS 26.0, *) { return try await AppleTranslator() }
        return try await WhisperTranslator(model: LiveView.translateModel)
    }
}

/// Settings switch for speech recognition. Both run on the iPad's Neural Engine.
enum RecognitionChoice: String, CaseIterable {
    case fast, accurate

    var label: String { self == .fast ? "Fast (large-v3 turbo)" : "Accurate (large-v3)" }
    // large-v3-v20240930 is OpenAI's large-v3-turbo: 4 decoder layers instead of 32, faster and
    // cooler, a little less accurate on lower-resource languages like Malay.
    var model: String { self == .fast ? "openai_whisper-large-v3-v20240930_626MB" : "openai_whisper-large-v3_947MB" }

    /// The Settings choice; an `--asr=fast|accurate` launch argument overrides it (for test runs).
    static var current: RecognitionChoice {
        let override = CommandLine.arguments.first { $0.hasPrefix("--asr=") }?.split(separator: "=").last
        return override.flatMap { Self(rawValue: String($0)) }
            ?? UserDefaults.standard.string(forKey: Pref.recognition).flatMap(Self.init) ?? .fast
    }
}

/// What gets saved next to the subtitles so replay can drive the same display.
struct SavedSession: Codable {
    var startDate: Date
    var audioOffset: Double       // session time of the first sample in the .caf
    var segments: [Segment]

    static func url(_ date: Date, _ ext: String) -> URL {
        URL.documentsDirectory.appending(path: "\(SubtitleExport.stem(date)).\(ext)")
    }
}

// MARK: - Live

struct LiveView: View {
    // Turbo can't translate, so Whisper translation uses full large-v3 (quantized).
    static let translateModel = "openai_whisper-large-v3_947MB"

    @AppStorage(Pref.exportFormat) private var format = SubtitleFormat.srt
    @AppStorage(Pref.bilingual) private var bilingual = true
    @AppStorage(Pref.saveRawAudio) private var saveRawAudio = true
    @AppStorage(Pref.customWords) private var customWords = ""
    @State private var timeline: SessionTimeline?
    @State private var recorder: RecorderActor?
    @State private var session: Task<Void, Never>?
    @State private var status = "Ready"
    @State private var exported: [URL] = []
    @State private var detail: Segment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if let timeline {
                    ZStack(alignment: .top) {
                        // Live: the active line is the newest committed segment. The road redraws only
                        // when a segment lands (10 Hz redraws heated the iPad); just the chrome ticks.
                        LyricsView(timeline: timeline, time: timeline.clock.now(),
                                   activeID: timeline.segments.last?.id,
                                   anchor: UnitPoint(x: 0.5, y: 0.7)) { detail = $0 }
                            .roadPerspective(reduceMotion: reduceMotion)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            DashboardChrome(timeline: timeline, time: timeline.clock.now(),
                                            elapsed: timeline.clock.now(), live: session != nil,
                                            status: ModelDownloads.shared.status ?? status)
                        }
                    }
                    .background(DashboardBackground())
                } else {
                    ContentUnavailableView("No session", systemImage: "mic", description: Text(status))
                }
            }
            .navigationTitle(ModelDownloads.shared.status ?? status)
            .overlay(alignment: .top) {
                if status == "Loading model…" || ModelDownloads.shared.status != nil {
                    ProgressView().controlSize(.large).padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if session == nil {
                        Button("Start", systemImage: "record.circle", action: start)
                    } else {
                        // Graceful stop flushes the last utterance; before the model loads there's nothing to flush.
                        Button("Stop", systemImage: "stop.circle") {
                            if let recorder { Task { await recorder.finish() } } else { session?.cancel() }
                        }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Export", systemImage: "square.and.arrow.down", action: export)
                        .disabled(timeline?.segments.isEmpty ?? true)
                    if !exported.isEmpty {
                        ShareLink(items: exported)
                    }
                }
            }
            .sheet(item: $detail) { SegmentDetail(segment: $0) }
        }
    }

    private func start() {
        let clock = SessionClock()
        let timeline = SessionTimeline(clock: clock)
        let audioURL = saveRawAudio ? SavedSession.url(timeline.startDate, "m4a") : nil
        self.timeline = timeline
        exported = []
        session = Task {
            defer { session = nil; recorder = nil }
            guard await AVAudioApplication.requestRecordPermission() else {
                status = "Microphone access denied"
                return
            }
            do {
                status = "Loading model…"
                // One after the other so two large downloads and ANE compiles don't fight.
                let recorder = try await RecorderActor(model: RecognitionChoice.current.model, clock: clock, rawAudioURL: audioURL,
                                                       customWords: customWords, language: SpokenLanguage.current)
                let translator = try await TranslatorChoice.current.load()
                self.recorder = recorder
                status = "Listening"
                // Recorder and translator run as sibling child tasks; cancelling this task stops both.
                try await timeline.run(record: { try await recorder.run(emit: $0) },
                                       translator: TranslatorActor(model: translator))
                let offset = await recorder.audioOrigin
                try JSONEncoder().encode(SavedSession(startDate: timeline.startDate, audioOffset: offset,
                                                      segments: timeline.segments))
                    .write(to: SavedSession.url(timeline.startDate, "json"))
                export()
                status = "Saved"
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func export() {
        guard let timeline else { return }
        do {
            exported = try SubtitleExport.write(timeline.segments, sessionDate: timeline.startDate,
                                                format: format, bilingual: bilingual, to: .documentsDirectory)
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Replay

struct SessionsView: View {
    @State private var files: [URL] = []
    @State private var importing = false
    @State private var progress: String?

    var body: some View {
        NavigationStack {
            List {
                if let progress {
                    Label(progress, systemImage: "waveform").foregroundStyle(.secondary)
                }
                ForEach(files, id: \.self) { url in
                    NavigationLink(url.deletingPathExtension().lastPathComponent) { ReplayView(url: url) }
                }
            }
            .overlay {
                if files.isEmpty && progress == nil {
                    ContentUnavailableView("No saved sessions", systemImage: "tray",
                                           description: Text("Record on the Live tab, or import a recording."))
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                Button("Import recording", systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(progress != nil)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
                guard case .success(let url) = result else { return }
                Task { await transcribe(url) }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        files = ((try? FileManager.default.contentsOfDirectory(at: .documentsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Imported files come from outside the sandbox: copy first, then transcribe the copy.
    private func transcribe(_ picked: URL) async {
        let copy = URL.temporaryDirectory.appending(path: picked.lastPathComponent)
        let access = picked.startAccessingSecurityScopedResource()
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: picked, to: copy)
        if access { picked.stopAccessingSecurityScopedResource() }
        progress = "Transcribing \(picked.lastPathComponent)…"
        do {
            _ = try await FileTranscriber.transcribe(copy) { timeline in
                progress = "Transcribing… \(timeline.segments.count) lines"
            }
            progress = nil
        } catch {
            progress = "Import failed: \(error.localizedDescription)"
        }
        try? FileManager.default.removeItem(at: copy)
        reload()
    }
}

struct ReplayView: View {
    let url: URL
    @State private var saved: SavedSession?
    @State private var timeline: SessionTimeline?
    @State private var player: AVAudioPlayer?
    @State private var levels: [Float] = []
    @State private var playing = false
    @State private var detail: Segment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let timeline, let saved {
                // Redraws only while playing; a paused replay costs nothing.
                TimelineView(.animation(minimumInterval: 0.05, paused: !playing)) { _ in
                    let position = player?.currentTime ?? 0
                    let time = position + saved.audioOffset
                    ZStack(alignment: .top) {
                        LyricsView(timeline: timeline, time: time,
                                   activeID: timeline.activeSegment(at: time)?.id,
                                   anchor: UnitPoint(x: 0.5, y: 0.7)) { segment in
                            player?.currentTime = max(0, segment.startTime - saved.audioOffset)
                            detail = segment
                        }
                        .roadPerspective(reduceMotion: reduceMotion)
                        DashboardChrome(timeline: timeline, time: time, elapsed: position, live: false,
                                        status: playing ? "Playing" : "Paused", levels: levels,
                                        progress: player.map { $0.duration > 0 ? position / $0.duration : 0 },
                                        seek: player.map { player in { player.currentTime = $0 * player.duration } })
                    }
                    .background(DashboardBackground())
                    .safeAreaInset(edge: .bottom) {
                        if let player {
                            RecordingPlayer(player: player, levels: levels, time: position, playing: $playing)
                        }
                    }
                    .onChange(of: player?.isPlaying) { _, isPlaying in
                        if isPlaying == false, playing, position >= (player?.duration ?? 0) - 0.1 { playing = false }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { SegmentDetail(segment: $0) }
        .task {
            guard let data = try? Data(contentsOf: url),
                  let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
            self.saved = saved
            timeline = SessionTimeline(startDate: saved.startDate, segments: saved.segments)
            // No recording when it was switched off: lines are still browsable, just not playable.
            // .caf is what builds before AAC recording wrote.
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            guard let audio = ["m4a", "caf"].map({ SavedSession.url(saved.startDate, $0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
            player = try? AVAudioPlayer(contentsOf: audio)
            player?.enableRate = true
            player?.prepareToPlay()
            levels = await Task.detached { RecordingPlayer.waveform(of: audio) }.value
        }
        .onDisappear { player?.stop() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Pref.exportFormat) private var format = SubtitleFormat.srt
    @AppStorage(Pref.bilingual) private var bilingual = true
    @AppStorage(Pref.wordHighlighting) private var wordHighlighting = true
    @AppStorage(Pref.saveRawAudio) private var saveRawAudio = true
    @AppStorage(Pref.translator) private var translator = TranslatorChoice.server
    @AppStorage(Pref.customWords) private var customWords = ""
    @AppStorage(Pref.recognition) private var recognition = RecognitionChoice.fast
    @AppStorage(Pref.spokenLanguage) private var spokenLanguage = SpokenLanguage.auto

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Translator", selection: $translator) {
                        ForEach(TranslatorChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    // Server falls back to Apple Translate, so its pack matters there too.
                    if translator != .whisper, #available(iOS 26.0, *) { ApplePackRow() }
                } header: {
                    Text("Translation")
                } footer: {
                    Text("N100 server translates on your home server (about 1 s per line) and keeps the iPad cool; it falls back to Apple Translate when unreachable. Apple Translate and Whisper large-v3 run on the iPad's Neural Engine; Whisper also translates other languages but is slower and runs warmer. Applies from the next session.")
                }
                Section {
                    Picker("Spoken language", selection: $spokenLanguage) {
                        ForEach(SpokenLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Model", selection: $recognition) {
                        ForEach(RecognitionChoice.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Recognition")
                } footer: {
                    Text("Malay + English suits classes that switch between the two: English is shown as it is, Malay is translated, and any other language is ignored. Pick Malay or English when the whole session is one language; it's more accurate. Accurate hears Malay better but works the iPad harder. Applies from the next session.")
                }
                Section {
                    TextField("Lembah Klang, Putrajaya, MRT Circle Line", text: $customWords, axis: .vertical)
                        .lineLimit(2...4)
                        .autocorrectionDisabled()
                } header: {
                    Text("Custom words")
                } footer: {
                    Text("Names, places and terms the speaker uses, separated by commas. Whisper is nudged toward these spellings. Applies from the next session.")
                }
                Section("Export") {
                    Picker("Format", selection: $format) {
                        Text("SRT").tag(SubtitleFormat.srt)
                        Text("WebVTT").tag(SubtitleFormat.vtt)
                    }
                    Toggle("Bilingual track", isOn: $bilingual)
                }
                Section {
                    Toggle("Word-by-word highlighting", isOn: $wordHighlighting)
                }
                Section {
                    Button("Run 200 wpm Malay test") { Task { await SpeedTest.shared.run() } }
                        .disabled(SpeedTest.shared.running)
                    if !SpeedTest.shared.report.isEmpty {
                        Text(SpeedTest.shared.report).font(.footnote.monospaced())
                    }
                } header: {
                    Text("Speed test")
                } footer: {
                    Text("Plays a one-minute news clip read at about 200 words per minute through the live pipeline and shows how far behind the text falls. Stop any live session first.")
                }
                Section {
                    Toggle("Save recording", isOn: $saveRawAudio)
                } footer: {
                    Text("Keeps a recording next to each session for replay and re-transcription with a larger model.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Shows whether Apple's Malay→English pack is on the device and offers the system download.
@available(iOS 26.0, *)
struct ApplePackRow: View {
    @State private var status = "Checking…"
    @State private var installed = false
    @State private var download: TranslationSession.Configuration?

    var body: some View {
        LabeledContent("Language pack", value: status)
            .translationTask(download) { session in
                // Shows Apple's download prompt for the pack.
                do { try await session.prepareTranslation() } catch { status = "Download failed" }
                await refresh()
            }
            .task { await refresh() }
        if !installed {
            Button("Download Malay \u{2192} English") {
                Task {
                    guard let source = await AppleTranslator.source(requiring: .supported) else {
                        status = "Not offered by Apple"
                        return
                    }
                    download = .init(source: source, target: AppleTranslator.english)
                }
            }
        }
    }

    private func refresh() async {
        if let language = await AppleTranslator.source(requiring: .installed) {
            installed = true
            status = language.languageCode?.identifier == "ms" ? "Malay installed" : "Using Indonesian (no Malay pack)"
        } else {
            installed = false
            status = await AppleTranslator.source(requiring: .supported) == nil ? "Not offered by Apple" : "Not downloaded"
        }
    }
}
