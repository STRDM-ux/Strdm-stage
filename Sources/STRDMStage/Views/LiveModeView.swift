import SwiftUI

/// Compact LIVE MIC control: lights follow whatever the microphone / line input hears.
struct LiveModeBar: View {
    @EnvironmentObject var live: LiveMode
    @EnvironmentObject var audio: AudioEngine
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 8) {
            Button { live.toggle() } label: {
                Label(live.running ? "LIVE MIC ON" : "Live Mic", systemImage: live.running ? "mic.fill" : "mic")
                    .font(.caption.weight(.heavy))
            }
            .buttonStyle(.borderedProminent)
            .tint(live.running ? .red : .gray)
            .help("Live mode: the lights, movers, lasers, visuals and crowd phones follow what the microphone hears")
            if live.running {
                Circle().fill(live.kickFlash ? Color.pink : Color.purple).frame(width: 9, height: 9)
                    .animation(.easeOut(duration: 0.08), value: live.kickFlash)
                Text(live.bpm > 0 ? "\(Int(live.bpm.rounded())) BPM" : "– BPM").font(.caption.monospacedDigit().weight(.bold))
                Text(live.section).font(.caption.weight(.semibold)).foregroundStyle(.pink)
                ProgressView(value: live.energy).frame(width: 50).tint(.orange)
            }
            Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .popover(isPresented: $showSettings) { LiveModeSettings().padding().frame(width: 340) }
        }
    }
}

struct LiveModeSettings: View {
    @EnvironmentObject var live: LiveMode
    @EnvironmentObject var audio: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Mode").font(.headline)
            Text("Listens to a mic or the desk feed and runs the stage in real time: tempo, kicks, builds, drops and breakdowns drive lights, movers, lasers, screen visuals and crowd phones. Effects still only fire when armed.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Input", selection: $live.inputUID) {
                Text("System default").tag(String?.none)
                ForEach(audio.inputDevices) { d in Text(d.name).tag(Optional(d.uid)) }
            }
            Picker("Vibe", selection: $live.vibe) {
                ForEach(Vibe.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: live.vibe) { _, _ in live.restyle() }
            Picker("Colours", selection: $live.paletteName) {
                ForEach(Palette.library) { Text($0.name).tag($0.name) }
            }
            .onChange(of: live.paletteName) { _, _ in live.restyle() }
            HStack {
                Text("Reacts")
                Slider(value: $live.sensitivity, in: 0...1)
                Text(live.sensitivity < 0.33 ? "Calm" : (live.sensitivity < 0.66 ? "Normal" : "Wild")).font(.caption).frame(width: 46)
            }
            HStack {
                Text("Input").font(.caption)
                ProgressView(value: live.level).tint(.green)
            }
            Text(live.status).font(.caption).foregroundStyle(.secondary)
            Text("Tip: feed it the DJ mixer or FOH desk output for the tightest beat lock. A room mic works too.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
