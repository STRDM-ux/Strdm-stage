import SwiftUI
import SceneKit
import UniformTypeIdentifiers
import os

/// Shared look settings for every 3D venue view (Live Map, pop-out, Stage Design, Effects).
@MainActor
final class Viewer3DSettings: ObservableObject {
    static let shared = Viewer3DSettings()

    enum CrowdSize: String, CaseIterable, Identifiable {
        case club, arena, festival, stadium
        var id: String { rawValue }
        var label: String {
            switch self {
            case .club: return "Club (~400)"
            case .arena: return "Arena (~1,500)"
            case .festival: return "Festival (~4,000)"
            case .stadium: return "Stadium (~9,000)"
            }
        }
        var rows: Int { switch self { case .club: return 14; case .arena: return 26; case .festival: return 44; case .stadium: return 70 } }
        var extraWidth: Double { switch self { case .club: return 4; case .arena: return 8; case .festival: return 22; case .stadium: return 40 } }
    }

    @Published var crowdSize: CrowdSize = CrowdSize(rawValue: UserDefaults.standard.string(forKey: "v3dCrowd") ?? "") ?? .arena {
        didSet { UserDefaults.standard.set(crowdSize.rawValue, forKey: "v3dCrowd") }
    }
    @Published var roof = UserDefaults.standard.object(forKey: "v3dRoof") as? Bool ?? true {
        didSet { UserDefaults.standard.set(roof, forKey: "v3dRoof") }
    }
    /// Extra atmosphere on top of what the hazer is doing (0…1).
    @Published var haze = UserDefaults.standard.object(forKey: "v3dHaze") as? Double ?? 0.35 {
        didSet { UserDefaults.standard.set(haze, forKey: "v3dHaze") }
    }
    @Published var daylight = false
    @Published var phoneLights = true
    @Published var fps = 0
    weak var activeController: Stage3DController?
}

/// Counts rendered frames on SceneKit's render thread.
final class FrameCounter: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        count.withLock { $0 += 1 }
    }
    func take() -> Int { count.withLock { v in let n = v; v = 0; return n } }
}

/// Second toolbar row for the 3D venue: movement choreographies, look, cold sparks and export.
struct Viewer3DBar: View {
    @EnvironmentObject var lighting: LightingEngine
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var crowd: CrowdController
    @ObservedObject var settings = Viewer3DSettings.shared
    @State private var showSparks = false
    @State private var pitchStatus: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Text("MOVEMENT").font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                ForEach(Array(MoverChoreo.allCases.enumerated()), id: \.element) { i, c in
                    Button {
                        lighting.choreo = lighting.choreo == c ? nil : c
                        if lighting.choreo != nil { lighting.followTargetID = nil }
                    } label: {
                        Label("\(i + 1) · \(c.label)", systemImage: c.symbol).font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(lighting.choreo == c ? .green : .gray)
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.option])
                    .help("⌥\(i + 1) — drives the real moving heads (pan/tilt) and the 3D view. Click again to stop.")
                }
                if lighting.choreo != nil {
                    Button("Stop") { lighting.choreo = nil }.tint(.red)
                }
                HStack(spacing: 4) {
                    Text("Speed").font(.caption)
                    Slider(value: $lighting.choreoSpeed, in: 0.25...4, step: 0.25).frame(width: 90)
                    Text(String(format: "%.2g×", lighting.choreoSpeed)).font(.caption.monospacedDigit()).frame(width: 34)
                }
                HStack(spacing: 4) {
                    Text("Size").font(.caption)
                    Slider(value: $lighting.choreoSize, in: 0.3...1.4).frame(width: 70)
                }
                Toggle("Open movers", isOn: $lighting.choreoLightsUp).toggleStyle(.button).font(.caption)
                    .help("Bring the movers' dimmers up while a choreography runs")

                Divider().frame(height: 20)

                Picker("", selection: $settings.crowdSize) {
                    ForEach(Viewer3DSettings.CrowdSize.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 150).help("Crowd size in the 3D venue")
                Toggle(isOn: $settings.phoneLights) { Label("Phones", systemImage: "iphone.radiowaves.left.and.right") }
                    .toggleStyle(.button).font(.caption)
                    .help("Crowd phones in 3D show what STRDM Live is sending to the audience's phones")
                Toggle(isOn: $settings.roof) { Label("Roof", systemImage: "house") }.toggleStyle(.button).font(.caption)
                    .help("Ground-support roof system over the stage")
                HStack(spacing: 4) {
                    Image(systemName: "cloud.fog").font(.caption)
                    Slider(value: $settings.haze, in: 0...1).frame(width: 70)
                }.help("Atmosphere — makes the beams read")
                Toggle(isOn: $settings.daylight) { Image(systemName: settings.daylight ? "sun.max.fill" : "moon.fill") }
                    .toggleStyle(.button).help("Day / night")

                Divider().frame(height: 20)

                Button { showSparks = true } label: { Label("Cold Sparks…", systemImage: "sparkles") }
                    .help("Add a line of cold spark units with live symmetry")
                Menu {
                    Button("Export 3D scene (USDZ — Blender, Reality Composer, Vectorworks)…") { exportUSDZ() }
                    Button("Export 3D scene (SceneKit .scn)…") { exportScene(ext: "scn") }
                    Divider()
                    Button(pitchStatus ?? "Publish 3D pitch link for clients") { publishPitch() }
                } label: { Label("Export 3D", systemImage: "square.and.arrow.up") }
                .fixedSize()

                Text("\(settings.fps) FPS")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(settings.fps >= 50 ? .green : settings.fps >= 30 ? .yellow : .red)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().stroke(Color.white.opacity(0.2)))
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(Color(white: 0.06))
        .sheet(isPresented: $showSparks) { SparkLineSheet() }
    }

    private func exportUSDZ() { exportScene(ext: "usdz") }

    private func exportScene(ext: String) {
        guard let c = settings.activeController else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = "\(store.show.name) Stage.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if c.export(to: url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func publishPitch() {
        pitchStatus = "Publishing…"
        Task {
            if crowd.logoURL == nil { await crowd.uploadLogo() }
            if let url = await PitchPublisher.publish(show: store.show, cloudURL: crowd.cloudURL, logo: crowd.logoURL) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                NSWorkspace.shared.open(url)
                pitchStatus = "Link copied — publish again"
            } else { pitchStatus = "Couldn't publish — online?" }
        }
    }
}

/// Adds a symmetric line of cold spark machines across the stage (like a Sparkular line).
struct SparkLineSheet: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @Environment(\.dismiss) private var dismiss
    @State private var width = 12.0
    @State private var count = 6
    @State private var position = 0        // 0 downstage edge, 1 upstage, 2 on the riser line
    @State private var replace = true
    @State private var kind: SFXKind = .coldSpark

    private var stageW: Double { store.show.stagePlot.stageWidth }
    private var xs: [Double] {
        let span = min(width, stageW)
        guard count > 1 else { return [stageW / 2] }
        return (0..<count).map { stageW / 2 - span / 2 + span * Double($0) / Double(count - 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add \(kind.label) line").font(.title2.weight(.heavy)).foregroundStyle(.orange)
                Spacer()
                Label("LIVE SYMMETRY", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.orange)
                    .padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange))
            }
            Picker("Effect", selection: $kind) {
                ForEach([SFXKind.coldSpark, .flame, .co2, .confetti]) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            HStack(spacing: 20) {
                VStack(alignment: .leading) {
                    Text("Width to cover (m)").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $width, in: 1...max(1, stageW), step: 0.5) {
                        Text(String(format: "%.1f m", min(width, stageW))).font(.title3.monospacedDigit().weight(.bold))
                    }
                }
                VStack(alignment: .leading) {
                    Text("Number of units").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $count, in: 1...24) { Text("\(count)").font(.title3.monospacedDigit().weight(.bold)) }
                }
            }
            Picker("Where", selection: $position) {
                Text("Downstage edge").tag(0)
                Text("Upstage").tag(1)
                Text("Mid-stage").tag(2)
            }.pickerStyle(.segmented)
            // Live preview of the spacing
            GeometryReader { g in
                let k = g.size.width / max(1, stageW)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 40)
                    ForEach(Array(xs.enumerated()), id: \.offset) { _, x in
                        Image(systemName: "sparkles").foregroundStyle(.black)
                            .padding(6).background(Circle().fill(.orange))
                            .position(x: x * k, y: 20)
                    }
                }
            }.frame(height: 40)
            Text(String(format: "%.2f m between units · centred on stage · %@", count > 1 ? min(width, stageW) / Double(count - 1) : 0,
                        "patched after your lights on universe 1"))
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Replace existing \(kind.plural.lowercased()) units", isOn: $replace)
            Text("Units are added disarmed. Arm and fire only from the Effects page with the safety key — never from a phone.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction).tint(.orange)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { width = min(width, stageW) }
    }

    private func save() {
        if replace { store.show.effects.devices.removeAll { $0.kind == kind } }
        let lights = lighting.fixtures.filter { $0.universe == 1 }.map(\.lastAddress).max() ?? 0
        let fx = store.show.effects.devices.filter { $0.universe == 1 }.map(\.lastAddress).max() ?? 0
        var address = min(510, max(lights, fx) + 1)
        let y = position == 0 ? 0.4 : position == 1 ? store.show.stagePlot.stageDepth - 0.6 : store.show.stagePlot.stageDepth * 0.5
        let existing = store.show.effects.devices.filter { $0.kind == kind }.count
        for (i, x) in xs.enumerated() {
            var d = SFXDevice.make(kind, number: existing + i + 1, universe: 1, address: address)
            d.stageX = (x * 100).rounded() / 100
            d.stageY = y
            store.show.effects.devices.append(d)
            address += d.footprint
        }
    }
}
