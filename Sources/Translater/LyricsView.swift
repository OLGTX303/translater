import SwiftUI
import TranslaterCore

/// Apple Music–style synced lines on a rolling drum (like the iOS picker wheel): lines tilt away
/// above and below the centre, the active line is big and opaque, its newest word zoomed.
struct LyricsView: View {
    let timeline: SessionTimeline
    let time: Double              // session clock time driving the highlight
    let activeID: Int?
    var anchor: UnitPoint = .center   // where the active line sits; the road view puts it low, nearest you
    let onTap: (Segment) -> Void
    @AppStorage(Pref.wordHighlighting) private var wordHighlighting = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(timeline.segments) { segment in
                        LyricLine(
                            segment: segment,
                            distance: activeID.map { abs(segment.id - $0) } ?? 99,
                            time: time,
                            wordHighlighting: wordHighlighting,
                            pending: timeline.isTranslationPending(segment)
                        )
                        .id(segment.id)
                        .contentShape(Rectangle())
                        .onTapGesture { onTap(segment) }
                        .scrollTransition(.interactive, axis: .vertical) { line, phase in
                            // phase.value: -1 at the top edge, 0 centred, 1 at the bottom edge.
                            line
                                .rotation3DEffect(.degrees(reduceMotion ? 0 : phase.value * -50),
                                                  axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                                .scaleEffect(1 - abs(phase.value) * 0.2)
                                .opacity(1 - abs(phase.value) * 0.6)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 320)       // first line can reach the anchor below the dashboard cards
                .padding(.bottom, 240)    // last line can reach it too
            }
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: activeID)
            .onChange(of: activeID) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85)) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            }
        }
    }
}

struct LyricLine: View {
    let segment: Segment
    let distance: Int             // 0 = active line
    let time: Double
    let wordHighlighting: Bool
    let pending: Bool

    var body: some View {
        let active = distance == 0
        VStack(alignment: .leading, spacing: 6) {
            malay
                .font(.title.bold())
            if let english = segment.english {
                Text(english)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else if pending {
                Text("translating…")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(active ? 1 : 0.82, anchor: .leading)
        .opacity(active ? 1 : max(0.2, 0.55 - 0.1 * Double(distance - 1)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var malay: Text {
        let prefix = Text(segment.marker).italic()
        // Word-by-word sync on the active line when timings exist; otherwise the whole line lights up.
        guard distance == 0, wordHighlighting, !segment.words.isEmpty else {
            return prefix + Text(segment.malay)
        }
        // The newest word reached so far is zoomed: the last word in live mode, the sung one in replay.
        let newest = segment.words.lastIndex { time >= $0.start }
        return segment.words.indices.reduce(prefix) { line, i in
            let word = segment.words[i]
            return line + Text(word.text + " ")
                .font(i == newest ? .largeTitle.bold() : .title.bold())
                .foregroundStyle(time >= word.start ? .primary : .tertiary)
        }
    }
}

struct SegmentDetail: View {
    let segment: Segment

    var body: some View {
        NavigationStack {
            List {
                Section("Time") {
                    LabeledContent("Start", value: SubtitleExport.timestamp(segment.startTime, .vtt))
                    LabeledContent("End", value: SubtitleExport.timestamp(segment.endTime, .vtt))
                }
                Section("Malay") { Text(segment.malay.isEmpty ? "[unclear]" : segment.malay).textSelection(.enabled) }
                Section("English") { Text(segment.english ?? "Not translated").textSelection(.enabled) }
                Section("Flags") {
                    LabeledContent("Low confidence", value: segment.isLowConfidence ? "Yes" : "No")
                    LabeledContent("Unclear", value: segment.isUnclear ? "Yes" : "No")
                    LabeledContent("Language", value: segment.otherLanguage ?? "Malay")
                }
                if !segment.words.isEmpty {
                    Section("Words") {
                        ForEach(Array(segment.words.enumerated()), id: \.offset) { _, word in
                            LabeledContent(word.text, value: SubtitleExport.timestamp(word.start, .vtt))
                        }
                    }
                }
            }
            .navigationTitle("Segment \(segment.id + 1)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
