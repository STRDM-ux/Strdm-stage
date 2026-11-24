import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

// MARK: - Sound

struct SoundPane: View {
    @EnvironmentObject var client: LiveClient
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var dragGain: [Int: Double] = [:]
    @State private var master: Double?
    @State private var lowCut: Double?

    var body: some View {
        let s = client.state
        ScrollView {
            if let eq = s?.eq {
                VStack(alignment: .leading, spacing: 16) {
                    // Master volume + meter
                    VStack(alignment: .leading, spacing: 8) {
                        let mg = master ?? s?.masterGain ?? 0
                        HStack {
                            Text("MASTER VOLUME").font(.caption.weight(.heavy)).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%+.1f dB", mg)).font(.title3.weight(.heavy).monospacedDigit())
                        }
                        Slider(value: Binding(get: { mg }, set: { master = $0; client.act("masterGain", ["value": $0]) }), in: -60...6, step: 0.5) { e in if !e { master = nil } }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(white: 0.12))
                                Capsule().fill(LinearGradient(colors: [.goGreen, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * min(1, s?.outputLevel ?? 0))
                            }
                        }
                        .frame(height: 10)
                    }
                    .padding(14).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 16))

                    HStack {
                        Text("10-BAND MASTER EQ").font(.caption.weight(.heavy)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle(eq.enabled ? "On" : "Bypassed", isOn: Binding(get: { eq.enabled }, set: { client.act("eqEnabled", ["on": $0]) }))
                            .fixedSize()
                    }
                    // Faders
                    HStack(alignment: .bottom, spacing: hSize == .regular ? 14 : 4) {
                        ForEach(eq.gains.indices, id: \.self) { i in
                            EQFader(label: eq.labels[safe: i] ?? "", gain: dragGain[i] ?? eq.gains[i],
                                    height: hSize == .regular ? 300 : 200) { g, done in
                                dragGain[i] = done ? nil : g
                                client.act("eqBand", ["band": i, "gain": g])
                            }
                        }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.card).clipShape(RoundedRectangle(cornerRadius: 16))
                    .opacity(eq.enabled ? 1 : 0.45)

                    let lc = lowCut ?? eq.lowCut
                    HStack {
                        Text("Low cut").font(.subheadline.weight(.semibold))
                        Slider(value: Binding(get: { lc }, set: { lowCut = $0; client.act("eqLowCut", ["value": $0]) }), in: 0...150, step: 5) { e in if !e { lowCut = nil } }
                        Text(lc < 20 ? "Off" : "\(Int(lc)) Hz").font(.subheadline.monospacedDigit()).frame(width: 60)
                    }
                    section("PRESETS")
                    grid(eq.presets.map { ($0, $0, $0 == eq.preset) }) { client.act("eqPreset", ["name": $0]) }

                    section("LIVE VOCAL")
                    if s?.vocalEnabled == true {
                        Button { client.act("vocalBypass", ["on": !(s?.vocalBypass ?? false)]) } label: {
                            Text(s?.vocalBypass == true ? "Dry vocal (FX bypassed)" : "🎤 Auto-Tune / FX ON")
                                .font(.headline).frame(maxWidth: .infinity).frame(height: 56)
                                .background(s?.vocalBypass == true ? Color.card : Color.strdmPink.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(PressStyle())
                        if let presets = s?.vocalPresets, !presets.isEmpty {
                            grid(presets.map { ($0.id, $0.name, false) }) { client.act("vocalPreset", ["id": $0]) }
                        }
                    } else {
                        Text("The vocal rack is off on the Mac.").foregroundStyle(.secondary)
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("Update STRDM Stage on the Mac for the EQ", systemImage: "slider.vertical.3")
            }
        }
    }
}

/// Vertical fader: drag to set ±12 dB, double-tap for 0.
struct EQFader: View {
    let label: String
    let gain: Double
    let height: CGFloat
    let onChange: (Double, Bool) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.1f", gain)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            GeometryReader { g in
                let h = g.size.height, knob: CGFloat = 26
                let y = (1 - (gain + 12) / 24) * (h - knob)
                ZStack(alignment: .top) {
                    Capsule().fill(Color(white: 0.05)).frame(width: 30)
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 26, height: 1).offset(y: h / 2)
                    let mid = h / 2, ky = y + knob / 2
                    Capsule().fill(LinearGradient(colors: [.strdmPink, .strdmPurple], startPoint: .top, endPoint: .bottom))
                        .frame(width: 8, height: abs(ky - mid)).offset(y: min(mid, ky))
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.92)).frame(width: 40, height: knob)
                        .shadow(radius: 3, y: 2).offset(y: y)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in onChange(value(v.location.y, h, knob), false) }
                    .onEnded { v in onChange(value(v.location.y, h, knob), true) })
                .onTapGesture(count: 2) { onChange(0, true) }
            }
            .frame(height: height)
            Text(label).font(.caption.weight(.heavy))
        }
        .frame(maxWidth: .infinity)
    }

    private func value(_ y: CGFloat, _ h: CGFloat, _ knob: CGFloat) -> Double {
        let p = max(0, min(h - knob, y - knob / 2))
        return ((12 - p / (h - knob) * 24) * 2).rounded() / 2
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Crowd phones

struct CrowdPane: View {
    @EnvironmentObject var client: LiveClient
    @State private var picks: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var text = ""
    @State private var speed: Double?
    @State private var bright: Double?
    @State private var showQR = false

    var body: some View {
        ScrollView {
            if let c = client.crowd {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("\(c.phones) phones in the show", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.headline).foregroundStyle(c.phones > 0 ? Color.goGreen : .secondary)
                        Spacer()
                        Button { showQR = true } label: { Label("Join QR", systemImage: "qrcode") }.buttonStyle(.bordered)
                    }
                    // Preview of what the crowd sees
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: c.colors.prefix(3).map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 70)
                        .overlay(Text(c.modes.first { $0.id == c.mode }?.name ?? c.mode).font(.headline).shadow(radius: 4))

                    section("MODE")
                    grid(c.modes.map { ($0.id, $0.name, $0.id == c.mode) }) { client.crowdSet(["mode": $0]) }

                    section("COLOURS")
                    HStack(spacing: 12) {
                        ForEach(c.colors.indices, id: \.self) { i in
                            ColorPicker("", selection: Binding(get: { Color(hex: c.colors[i]) }, set: { col in
                                var cols = c.colors; cols[i] = col.hexString; client.crowdSet(["colors": cols])
                            }), supportsOpacity: false)
                            .labelsHidden().scaleEffect(1.5).frame(width: 50, height: 50)
                        }
                        Spacer()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.palettes, id: \.0) { p in
                                Button { client.crowdSet(["colors": p.1]) } label: {
                                    HStack(spacing: 0) { ForEach(p.1, id: \.self) { Color(hex: $0).frame(width: 22, height: 30) } }
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(Text(p.0).font(.caption2.weight(.bold)).shadow(radius: 2).offset(y: 24))
                                        .padding(.bottom, 14)
                                }
                            }
                        }
                    }

                    let sp = speed ?? c.speed, br = bright ?? c.bright
                    HStack { Text("Speed").frame(width: 80, alignment: .leading)
                        Slider(value: Binding(get: { sp }, set: { speed = $0; client.crowdSet(["speed": $0]) }), in: 0.25...4) { e in if !e { speed = nil } }
                        Text(String(format: "%.2g×", sp)).monospacedDigit().frame(width: 44) }
                    HStack { Text("Brightness").frame(width: 80, alignment: .leading)
                        Slider(value: Binding(get: { br }, set: { bright = $0; client.crowdSet(["bright": $0]) }), in: 0.1...1) { e in if !e { bright = nil } }
                        Text("\(Int(br * 100))%").monospacedDigit().frame(width: 44) }

                    section("TEXT ON EVERY PHONE")
                    HStack {
                        TextField("ARMANII · PUT YOUR LIGHTS UP", text: $text).textFieldStyle(.roundedBorder)
                        Button("Show") { client.crowdSet(["text": text, "mode": "text"]) }.buttonStyle(.borderedProminent).disabled(text.isEmpty)
                    }

                    section("IMAGES & VIDEOS")
                    PhotosPicker(selection: $picks, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                        Label(uploading ? "Sending to the Mac…" : "Add from Photos", systemImage: uploading ? "arrow.up.circle" : "plus.circle.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered).disabled(uploading)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(c.media) { m in
                            Button { client.crowdSet(["media": m.id]) } label: {
                                ZStack(alignment: .bottomLeading) {
                                    if m.kind == "image", let u = client.mediaURL(m.url) {
                                        AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Color.card }
                                    } else {
                                        Color.card.overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary))
                                    }
                                    Text(m.name).font(.caption2.weight(.semibold)).lineLimit(1).padding(4).background(.black.opacity(0.6))
                                }
                                .frame(height: 90).frame(maxWidth: .infinity).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(c.current == m.id && (c.mode == "image" || c.mode == "video") ? Color.strdmPink : .clear, lineWidth: 3))
                            }
                            .buttonStyle(PressStyle())
                            .contextMenu { Button("Remove", role: .destructive) { client.crowdSet(["removeMedia": m.id]) } }
                        }
                    }
                    Text("The audience scans the join QR on the venue Wi-Fi, taps Join and holds their phones up. Effects run on each phone in sync with the beat; videos play muted.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            } else {
                VStack(spacing: 10) { ProgressView(); Text("Loading crowd control…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            uploading = true
            Task {
                for item in items {
                    let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
                        _ = await client.uploadCrowdMedia(data, name: "Phone \(Int(Date().timeIntervalSince1970) % 100000).\(ext)")
                    }
                }
                picks = []
                uploading = false
            }
        }
        .sheet(isPresented: $showQR) {
            if let c = client.crowd { JoinQRSheet(url: c.joinURL) }
        }
    }

    static let palettes: [(String, [String])] = [
        ("Pink & Purple", ["#FF1493", "#7A00FF", "#FFFFFF"]), ("Yaad", ["#00B140", "#FFC600", "#FF2A00"]),
        ("Fire", ["#FF2000", "#FF8C00", "#FFFFFF"]), ("Ice", ["#00C8FF", "#FFFFFF", "#3A5BFF"]),
        ("Neon", ["#00FF6A", "#FF00E1", "#FFFF00"]), ("Sunset", ["#FF6A00", "#FF2E7E", "#FFD27A"])
    ]
}

struct JoinQRSheet: View {
    let url: String
    var body: some View {
        VStack(spacing: 18) {
            Text("Scan to join the light show").font(.title2.bold())
            if let img = QR.image(url) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 320)
                    .padding(16).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 16))
            }
            Text(url).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Phones must be on the venue Wi-Fi.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(30)
        .presentationDetents([.large])
    }
}

enum QR {
    static func image(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension Color {
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}
