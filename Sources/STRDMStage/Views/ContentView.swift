import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case cues, crew, studio, liveMap, setBuilder, audio, lighting, effects, screens, stagePlot, advance, control
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cues: return "Cue List"
        case .crew: return "AI Crew"
        case .studio: return "Studio & Vocals"
        case .liveMap: return "Live Stage Map"
        case .setBuilder: return "Light Set Builder"
        case .audio: return "Audio & Vocals"
        case .lighting: return "Lighting"
        case .effects: return "Special Effects"
        case .screens: return "Screens"
        case .stagePlot: return "Stage Plot & Inputs"
        case .advance: return "Venue Advance"
        case .control: return "Control & Log"
        }
    }
    var symbol: String {
        switch self {
        case .cues: return "list.number"
        case .crew: return "person.2.badge.gearshape.fill"
        case .studio: return "pianokeys.inverse"
        case .liveMap: return "light.beacon.max.fill"
        case .setBuilder: return "wand.and.stars"
        case .audio: return "waveform.and.mic"
        case .lighting: return "lightbulb.2.fill"
        case .effects: return "flame.fill"
        case .screens: return "tv.and.mediabox"
        case .stagePlot: return "square.grid.3x3.topleft.filled"
        case .advance: return "building.2.fill"
        case .control: return "dot.radiowaves.left.and.right"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            // Audio & Vocals lives inside the Studio now (one place for tracks, mixing, vocals and I/O).
            List(AppSection.allCases.filter { $0 != .audio }, selection: $model.section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .top) { BrandHeader() }
            .safeAreaInset(edge: .bottom) { ShowNameFooter() }
        } detail: {
            VStack(spacing: 0) {
                TransportBar()
                Divider()
                Group {
                    switch model.section ?? .cues {
                    case .cues: CueListView()
                    case .crew: CrewView()
                    case .studio: StudioView()
                    case .liveMap: LiveStageMapView()
                    case .setBuilder: LightSetBuilderView()
                    case .audio: StudioView(openAudio: true)
                    case .lighting: LightingView()
                    case .effects: EffectsView()
                    case .screens: ScreensView()
                    case .stagePlot: StagePlotView()
                    case .advance: VenueAdvanceView()
                    case .control: ControlView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store.windowTitle)
        .alert("STRDM Stage", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

private struct ShowNameFooter: View {
    @EnvironmentObject var store: ShowStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SHOW").font(.caption2).foregroundStyle(.secondary)
            TextField("Show name", text: $store.show.name)
                .textFieldStyle(.plain)
                .font(.headline)
            HStack {
                Button("Save") { store.save() }
                if store.isDirty { Circle().fill(.orange).frame(width: 7, height: 7) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(12)
    }
}

// MARK: - Transport

struct TransportBar: View {
    @EnvironmentObject var engine: ShowEngine

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Button { engine.go() } label: {
                Text("GO")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .frame(width: 120, height: 64)
            }
            .buttonStyle(GoButtonStyle())
            .help("GO — fires the standby cue (Space)")

            StandbyPanel()
                .frame(minWidth: 260, maxWidth: 380, alignment: .leading)

            RunningCuesStrip()
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button("Stop All") { engine.stopAll() }
                        .keyboardShortcut(".", modifiers: .command)
                    Button("Panic") { engine.panic() }
                        .tint(.red)
                }
                SFXStatusPill()
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                HStack(spacing: 8) {
                    TransportMeter()
                    TransportBlackout()
                }
            }
            ClockView()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.35))
    }
}

struct GoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(configuration.isPressed ? Color.green.opacity(0.6) : Color.green)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.4), lineWidth: 1))
            .shadow(color: .green.opacity(0.5), radius: configuration.isPressed ? 2 : 10)
    }
}

private struct StandbyPanel: View {
    @EnvironmentObject var engine: ShowEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("STANDBY").font(.caption2.weight(.bold)).foregroundStyle(.green)
            if let cue = engine.standbyCue {
                HStack(spacing: 8) {
                    Text(cue.number).font(.title2.monospacedDigit().weight(.bold))
                    Image(systemName: cue.kind.symbol).foregroundStyle(cue.kind.tint)
                    Text(cue.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                }
                if !cue.notes.isEmpty {
                    Text(cue.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text("End of cue list").font(.title3).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RunningCuesStrip: View {
    @EnvironmentObject var engine: ShowEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if engine.running.isEmpty {
                        Text("Nothing running").foregroundStyle(.tertiary).font(.callout)
                    }
                    ForEach(engine.running) { run in
                        RunningChip(run: run, now: context.date)
                    }
                }
            }
        }
    }
}

private struct RunningChip: View {
    let run: RunningCue
    let now: Date

    var body: some View {
        let elapsed = now.timeIntervalSince(run.startedAt)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: run.kind.symbol).foregroundStyle(run.kind.tint)
                Text("\(run.cueNumber) \(run.title)").lineLimit(1).font(.caption.weight(.semibold))
            }
            HStack(spacing: 6) {
                if let d = run.duration, d > 0 {
                    ProgressView(value: min(1, max(0, elapsed / d)))
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                        .tint(run.phase == .preWait ? .orange : run.kind.tint)
                    Text(formatTime(max(0, d - elapsed))).font(.caption2.monospacedDigit())
                } else {
                    Text(formatTime(elapsed)).font(.caption2.monospacedDigit())
                    Text("∞").font(.caption2)
                }
                if run.phase == .preWait { Text("pre-wait").font(.caption2).foregroundStyle(.orange) }
                if run.phase == .fading { Text("fading").font(.caption2).foregroundStyle(.teal) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
    }
}

private struct ClockView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.date.formatted(date: .omitted, time: .standard))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Text(context.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            let db = level > 0 ? 20 * log10(Double(level)) : -60
            let fraction = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction)
                    .mask(alignment: .leading) { Capsule() }
            }
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = Int(seconds.rounded(.down))
    let tenths = Int((seconds - Double(s)) * 10)
    return String(format: "%d:%02d.%d", s / 60, s % 60, max(0, min(9, tenths)))
}


/// STRDM Live logo at the top of the sidebar.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            if let img = NSImage(named: "BrandMark") {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .shadow(color: Color(red: 0, green: 0.9, blue: 1).opacity(0.5), radius: 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("STRDM LIVE").font(.system(size: 13, weight: .black)).tracking(2)
                    .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.24, blue: 0.51), Color(red: 0, green: 0.9, blue: 1)],
                                                    startPoint: .leading, endPoint: .trailing))
                Text("Stage").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}


/// Split out so 40 Hz lighting frames and audio meters only redraw these, not the whole transport bar.
private struct TransportMeter: View {
    @EnvironmentObject var audio: AudioEngine
    var body: some View { LevelMeter(level: audio.outputLevel).frame(width: 90, height: 8) }
}

private struct TransportBlackout: View {
    @EnvironmentObject var lighting: LightingEngine
    var body: some View {
        Toggle("Blackout", isOn: $lighting.blackout)
            .toggleStyle(.button)
            .tint(.yellow)
            .controlSize(.small)
    }
}
