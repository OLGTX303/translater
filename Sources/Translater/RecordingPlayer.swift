import AVFoundation
import SwiftUI

/// Voice Memos–style transport under the synced lines: a waveform you can drag to scrub,
/// elapsed/remaining time, ±15 s skips, play/pause and playback speed.
struct RecordingPlayer: View {
    let player: AVAudioPlayer
    let levels: [Float]           // 0...1 per bar, from `waveform(of:)`
    let time: TimeInterval        // player.currentTime, refreshed by the caller's TimelineView
    @Binding var playing: Bool
    @State private var speed: Float = 1

    var body: some View {
        VStack(spacing: 12) {
            Waveform(levels: levels, progress: player.duration > 0 ? time / player.duration : 0) { fraction in
                player.currentTime = fraction * player.duration
            }
            .frame(height: 56)
            HStack {
                Text(Self.clock(time))
                Spacer()
                Text("-" + Self.clock(max(0, player.duration - time)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack(spacing: 44) {
                Menu {
                    ForEach([0.5, 1, 1.5, 2] as [Float], id: \.self) { rate in
                        Button("\(rate.formatted())×") { speed = rate; player.rate = rate }
                    }
                } label: {
                    Text("\(speed.formatted())×").font(.callout.weight(.semibold)).frame(width: 44)
                }
                Button("Back 15 seconds", systemImage: "gobackward.15") { skip(-15) }
                    .labelStyle(.iconOnly).font(.title2)
                Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                    if playing { player.pause() } else { player.play() }
                    playing.toggle()
                }
                .labelStyle(.iconOnly).font(.largeTitle)
                Button("Forward 15 seconds", systemImage: "goforward.15") { skip(15) }
                    .labelStyle(.iconOnly).font(.title2)
                Color.clear.frame(width: 44, height: 1)   // balances the speed menu
            }
            .tint(.primary)
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .padding(.horizontal)
        .onAppear { player.enableRate = true }   // must be set before play() for speed changes to work
    }

    private func skip(_ seconds: TimeInterval) {
        player.currentTime = min(max(0, player.currentTime + seconds), player.duration)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Peak level per bar across the whole file, scaled to the loudest bar.
    static func waveform(of url: URL, bars: Int = 120) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0] else { return [] }
        let perBar = max(1, Int(buffer.frameLength) / bars)
        let peaks = (0..<bars).map { bar in
            let start = bar * perBar
            let end = min(Int(buffer.frameLength), start + perBar)
            return start < end ? (start..<end).reduce(Float(0)) { max($0, abs(samples[$1])) } : 0
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }
}

private struct Waveform: View {
    let levels: [Float]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / Double(max(1, levels.count)) <= progress ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(height: max(3, CGFloat(levels[i]) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                seek(min(max(0, drag.location.x / geo.size.width), 1))
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            seek(min(max(0, progress + (direction == .increment ? 0.05 : -0.05)), 1))
        }
    }
}
