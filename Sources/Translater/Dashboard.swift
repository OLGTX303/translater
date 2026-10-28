import SwiftUI
import TranslaterCore

// The Tesla main-screen layout around the subtitles: a thin status strip, a trip-style card at
// top-left (here a words-per-minute "speedometer"), a mini map at top-right (the session's route,
// with the playhead as the car), and the subtitle drum as the road scene in between.

/// The overlay that sits on top of the road. `time` is the session clock; `elapsed` is what the
/// strip shows (recording time live, playhead position in replay).
struct DashboardChrome: View {
    let timeline: SessionTimeline
    let time: Double
    let elapsed: Double
    let live: Bool
    let status: String
    var levels: [Float] = []                  // replay: the recording's waveform as the route
    var progress: Double? = nil               // replay: playhead 0...1
    var seek: ((Double) -> Void)? = nil       // replay: tap or drag the map
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 12) {
            StatusStrip(live: live, elapsed: elapsed)
            HStack(alignment: .top, spacing: 16) {
                SpeedCard(timeline: timeline, time: time, live: live, status: status)
                Spacer(minLength: 0)
                if sizeClass != .compact {
                    MiniMap(timeline: timeline, time: time, levels: levels, progress: progress, seek: seek)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

private struct StatusStrip: View {
    let live: Bool
    let elapsed: Double
    @AppStorage(Pref.translator) private var translator = TranslatorChoice.server

    var body: some View {
        HStack(spacing: 14) {
            if live {
                Label(RecordingPlayer.clock(elapsed), systemImage: "circle.fill")
                    .foregroundStyle(.red)
            } else {
                Label(RecordingPlayer.clock(elapsed), systemImage: "play.fill")
                    .foregroundStyle(.secondary)
            }
            Text(SpokenLanguage.current.route).foregroundStyle(.secondary)
            Text(translator.label).foregroundStyle(.blue)
            Spacer()
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                Image(systemName: "thermometer.high").foregroundStyle(.orange)
                    .accessibilityLabel("Device is hot")
            }
            Text(Date.now, style: .time).foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}

/// Tesla's "Arriving in 13 min" card, as a speedometer: words per minute over the last minute.
private struct SpeedCard: View {
    let timeline: SessionTimeline
    let time: Double
    let live: Bool
    let status: String

    var body: some View {
        let segments = timeline.segments
        VStack(alignment: .leading, spacing: 4) {
            Text(live ? "Live · \(SpokenLanguage.current.label)" : "Replay")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(wordsPerMinute.map(String.init) ?? "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("WPM").font(.headline).foregroundStyle(.secondary)
            }
            Text("\(segments.count) lines · \(segments.filter { $0.english != nil }.count) in English")
                .font(.subheadline)
            Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(width: 230, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    /// Words in lines that ended within the last minute, scaled to a minute while the session is younger.
    private var wordsPerMinute: Int? {
        guard let first = timeline.segments.first else { return nil }
        let window = min(60, time - first.startTime)
        guard window > 5 else { return nil }
        let words = timeline.segments
            .filter { $0.endTime > time - 60 && $0.startTime <= time }
            .reduce(0) { $0 + $1.malay.split(separator: " ").count }
        return Int(Double(words) / window * 60)
    }
}

/// Tesla's mini map: the session as a blue route (speech density live, the waveform in replay),
/// a red marker where you are, faint grid streets behind. Tap or drag to seek in replay.
private struct MiniMap: View {
    let timeline: SessionTimeline
    let time: Double
    let levels: [Float]
    let progress: Double?
    let seek: ((Double) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session map").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Canvas { context, size in
                drawStreets(context, size)
                let points = route(in: size)
                guard points.count > 1 else { return }
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(.blue), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                let at = progress ?? 1
                let marker = points[min(points.count - 1, Int(at * Double(points.count - 1)))]
                var arrow = Path()
                arrow.move(to: CGPoint(x: marker.x, y: marker.y - 9))
                arrow.addLine(to: CGPoint(x: marker.x + 7, y: marker.y + 6))
                arrow.addLine(to: CGPoint(x: marker.x - 7, y: marker.y + 6))
                arrow.closeSubpath()
                context.fill(arrow, with: .color(.red))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard let seek else { return }
                seek(min(max(0, drag.location.x / 250), 1))
            })
        }
        .padding(12)
        .frame(width: 274, height: 150)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .accessibilityElement()
        .accessibilityLabel("Session map")
        .accessibilityValue(progress.map { "\(Int($0 * 100)) percent through" } ?? "\(timeline.segments.count) lines")
    }

    private func drawStreets(_ context: GraphicsContext, _ size: CGSize) {
        var streets = Path()
        for x in stride(from: 0, through: size.width, by: 34) {
            streets.move(to: CGPoint(x: x, y: 0)); streets.addLine(to: CGPoint(x: x + 18, y: size.height))
        }
        for y in stride(from: 0, through: size.height, by: 26) {
            streets.move(to: CGPoint(x: 0, y: y)); streets.addLine(to: CGPoint(x: size.width, y: y - 8))
        }
        context.stroke(streets, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
    }

    /// One point per waveform bar (replay) or per line (live), left to right through the session.
    private func route(in size: CGSize) -> [CGPoint] {
        let heights: [Double]
        if !levels.isEmpty {
            heights = levels.map(Double.init)
        } else {
            // Words per second per line: busier stretches climb higher.
            heights = timeline.segments.map {
                min(1, Double($0.malay.split(separator: " ").count) / max(0.5, $0.endTime - $0.startTime) / 5)
            }
        }
        guard heights.count > 1 else { return [] }
        return heights.enumerated().map { i, h in
            CGPoint(x: 8 + (size.width - 16) * Double(i) / Double(heights.count - 1),
                    y: size.height - 8 - (size.height - 16) * h)
        }
    }
}

extension View {
    /// The road: the subtitle drum tilted back from its bottom edge so older lines recede into the
    /// distance and fade out under the cards, like Tesla's driving view.
    func roadPerspective(reduceMotion: Bool) -> some View {
        rotation3DEffect(.degrees(reduceMotion ? 0 : 24), axis: (x: 1, y: 0, z: 0),
                         anchor: .bottom, perspective: 0.45)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0.12), .init(color: .black, location: 0.42)],
                                 startPoint: .top, endPoint: .bottom))
    }
}

/// Tesla's pale, flat backdrop.
struct DashboardBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(.systemGray5), Color(.systemGroupedBackground)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}
