import SwiftUI
import AppKit

struct ScreensView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var screens: ScreenManager

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Open all outputs") { screens.openAllOutputs() }
                        .buttonStyle(.borderedProminent)
                    Button("Close all") { screens.closeAllOutputs() }
                    Toggle("Test pattern", isOn: Binding(get: { screens.testPatternOn }, set: { screens.setTestPattern($0) }))
                        .toggleStyle(.button)
                    Spacer()
                    Button {
                        store.show.screens.append(ScreenOutput(name: "Output \(store.show.screens.count + 1)"))
                    } label: { Label("Add output", systemImage: "plus") }
                }
                Text("Plug the LED processor / projector in as an extended display (not mirrored). Pick it below, untick “Preview window”, then open the output. Audio for videos runs as separate audio cues so it goes through your main interface.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Send to screens") {
                QuickSendPanel()
            }

            Section("Crowd Phones — the audience is the light show") {
                CrowdPanel()
            }

            Section("Generated 3D visuals") {
                VisualsControls()
            }

            Section("Outputs") {
                ForEach($store.show.screens) { $output in
                    ScreenOutputRow(output: $output)
                }
            }

            Section("Connected displays") {
                ForEach(screens.displays) { d in
                    HStack {
                        Image(systemName: d.isMain ? "laptopcomputer" : "tv")
                        Text(d.name)
                        if d.isMain { Text("operator screen").font(.caption).foregroundStyle(.orange) }
                        Spacer()
                        Text("\(Int(d.pixelSize.width)) × \(Int(d.pixelSize.height)) px · \(ScreenManager.aspectLabel(d.pixelSize))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Button("Rescan displays") { screens.refreshDisplays() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScreenOutputRow: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var screens: ScreenManager
    @Binding var output: ScreenOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(screens.isOpen(output.id) ? Color.green : Color.gray).frame(width: 9, height: 9)
                TextField("Name", text: $output.name).font(.headline).textFieldStyle(.plain)
                Spacer()
                if let list = screens.layers[output.id], !list.isEmpty {
                    Label(list.joined(separator: " + "), systemImage: "square.stack.fill").font(.caption).foregroundStyle(.purple)
                        .lineLimit(1)
                    Button("Clear") { screens.clear(screenID: output.id) }.controlSize(.small)
                }
            }
            HStack {
                Picker("Display", selection: $output.displayID) {
                    Text("None (preview window only)").tag(UInt32?.none)
                    ForEach(screens.displays) { d in
                        Text(d.isMain ? "\(d.name) (operator!)" : d.name).tag(Optional(d.id))
                    }
                }
                Toggle("Preview window", isOn: $output.windowed)
            }
            if let px = screens.pixelSize(for: output.id) {
                Label("Detected \(Int(px.width)) × \(Int(px.height)) · \(ScreenManager.aspectLabel(px)) — media auto-fits to this",
                      systemImage: "viewfinder").font(.caption).foregroundStyle(.green)
            }
            Toggle("Blurred edges instead of black bars (Auto fit)",
                   isOn: Binding(get: { output.blurEdges != false }, set: { output.blurEdges = $0 }))
            Toggle("Auto 3D visuals during song light shows",
                   isOn: Binding(get: { output.autoVisuals != false }, set: { output.autoVisuals = $0 }))
            HStack {
                if screens.isOpen(output.id) {
                    Button("Close output") { screens.closeOutput(output.id) }
                } else {
                    Button("Open output") { screens.openOutput(output.id) }
                }
                Button("Re-open with new settings") { screens.openOutput(output.id) }
                    .disabled(!screens.isOpen(output.id))
                Spacer()
                Button(role: .destructive) {
                    screens.closeOutput(output.id)
                    store.show.screens.removeAll { $0.id == output.id }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(store.show.screens.count <= 1)
            }
            if let id = output.displayID, screens.displays.first(where: { $0.id == id })?.isMain == true, !output.windowed {
                Text("Full-screen on the operator display will cover this window. Use an external display for shows.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct VisualsControls: View {
    @EnvironmentObject var visuals: VisualEngine
    @EnvironmentObject var screens: ScreenManager
    @State private var showTitle = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VisualPreview()
                .frame(width: 320, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 8) {
                Text("Song light shows drive the screens too: same colours, a visual per section, pulses on the beat, white flashes on drop hits.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Now:")
                    Text(visuals.activeStyle.label).fontWeight(.semibold)
                    if !screens.visualsOnScreens.isEmpty {
                        Text("· live on \(screens.visualsOnScreens.count) screen(s)").foregroundStyle(.green)
                    }
                }
                Picker("Override", selection: $visuals.manualStyle) {
                    Text("Auto (follow the song)").tag(VisualStyle?.none)
                    ForEach(VisualStyle.allCases) { Text($0.label).tag(Optional($0)) }
                }
                .frame(maxWidth: 320)
                HStack {
                    TextField("Name on screen", text: $visuals.titleText)
                        .frame(maxWidth: 220)
                    Button("3D Title…") { showTitle = true; visuals.manualStyle = .text }
                        .popover(isPresented: $showTitle, arrowEdge: .bottom) { TitleEditor().frame(width: 420) }
                }
                Text("Choosing an override also shows it on the screens without a song running, which is handy for walk-in.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}


/// Edits the 3D title: text, material, animation, font, bevel and AI backdrop art.
struct TitleEditor: View {
    @EnvironmentObject var visuals: VisualEngine
    private static let fonts: [String] = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Form {
            Section("Text") {
                TextField("Title", text: $visuals.title.text)
                TextField("Second line (tour, venue, date…)", text: $visuals.title.subtitle)
                Toggle("Show the current song's name instead", isOn: $visuals.title.useSongName)
            }
            Section("Look") {
                Picker("Material", selection: $visuals.title.material) {
                    ForEach(TitleMaterial.allCases) { Text($0.label).tag($0) }
                }
                Picker("Animation", selection: $visuals.title.motion) {
                    ForEach(TitleAnimation.allCases) { Text($0.label).tag($0) }
                }
                Picker("Font", selection: $visuals.title.fontName) {
                    Text("Heavy (system)").tag("")
                    ForEach(Self.fonts, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Depth") { Slider(value: $visuals.title.depth, in: 0.1...2) }
                LabeledContent("Bevel") { Slider(value: $visuals.title.bevel, in: 0...0.2) }
                Toggle("Glowing rings behind", isOn: $visuals.title.showHalos)
            }
            Section("Backdrop art") {
                HStack {
                    Text(visuals.title.backdropPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = MediaSupport.imageTypes
                        if panel.runModal() == .OK, let url = panel.url { visuals.title.backdropPath = url.path }
                    }
                    if visuals.title.backdropPath != nil {
                        Button("Clear") { visuals.title.backdropPath = nil }
                    }
                }
                if visuals.title.backdropPath != nil {
                    LabeledContent("Opacity") { Slider(value: $visuals.title.backdropOpacity, in: 0...1) }
                }
                Text("Use AI title art (e.g. from Higgsfield) as the backdrop — chrome and gold letters also reflect it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
    }
}


/// Pick a video or image and throw it on any screen, area, or all screens at once — resized to fit.
private struct QuickSendPanel: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var engine: ShowEngine
    @EnvironmentObject var screens: ScreenManager
    @State private var cue = Cue(kind: .video, name: "Quick send")
    @State private var dropHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(dropHover ? Color.purple.opacity(0.3) : Color.black.opacity(0.3))
                    RoundedRectangle(cornerRadius: 8).stroke(Color.purple.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    VStack(spacing: 4) {
                        Image(systemName: cue.videoPath == nil ? "photo.on.rectangle.angled" : "checkmark.circle.fill")
                            .font(.title2).foregroundStyle(.purple)
                        Text(cue.videoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Drop a video or image")
                            .font(.caption).lineLimit(1)
                    }
                    .padding(6)
                }
                .frame(width: 220, height: 80)
                .onTapGesture {
                    if let u = pickFiles(MediaSupport.videoTypes + MediaSupport.imageTypes).first { cue.videoPath = u.path }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first else { return false }
                    cue.videoPath = u.path
                    return true
                } isTargeted: { dropHover = $0 }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("Area", selection: Binding(get: { cue.region ?? .full }, set: { cue.region = $0 == .full ? nil : $0 })) {
                            ForEach(ScreenRegion.allCases) { Text($0.label).tag($0) }
                        }
                        .frame(maxWidth: 260)
                        RegionThumb(region: cue.region ?? .full).frame(width: 56, height: 32)
                    }
                    Picker("Resize", selection: Binding(get: { cue.effectiveFit }, set: { cue.fitMode = $0 })) {
                        ForEach(FitMode.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 260)
                    AutoFitSummary(cue: cue)
                    HStack {
                        Toggle("Layer on top", isOn: Binding(get: { cue.overlay == true }, set: { cue.overlay = $0 ? true : nil }))
                        Toggle("Loop", isOn: $cue.videoLoop)
                    }
                }
            }
            HStack {
                Button {
                    send(all: true, screen: nil)
                } label: { Label("Send to All Screens", systemImage: "rectangle.3.group.fill") }
                .buttonStyle(.borderedProminent).tint(.purple)
                .disabled(cue.videoPath == nil)
                ForEach(store.show.screens) { sc in
                    Button(sc.name) { send(all: false, screen: sc.id) }
                        .disabled(cue.videoPath == nil)
                }
                Spacer()
                Button("Add as Cue") {
                    var c = cue
                    c.id = UUID()
                    c.number = store.nextCueNumber()
                    c.name = cue.videoPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Video"
                    if c.allScreens == nil && c.screenID == nil { c.allScreens = true }
                    c.videoSound = false
                    store.show.cues.append(c)
                }
                .disabled(cue.videoPath == nil)
                Button("Clear All Screens") { screens.stopAll(fade: 0.5) }
            }
            Text("Every screen resizes the media to its own size. Pick an area to put several things on one screen (e.g. video on the left, flyer on the right, logo in a corner).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func send(all: Bool, screen: UUID?) {
        var c = cue
        c.id = UUID()
        c.allScreens = all ? true : nil
        c.screenID = screen
        c.screenIDs = nil
        c.videoSound = false
        c.videoFade = 0.5
        engine.fireAdHoc(c)
    }
}


/// Shows what Auto fit will do on each target screen for this cue's media.
struct AutoFitSummary: View {
    @EnvironmentObject var screens: ScreenManager
    let cue: Cue
    var body: some View {
        if cue.effectiveFit == .auto, cue.videoPath != nil {
            let lines = screens.autoFitSummary(for: cue)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { Text($0) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}


/// Audience phones: join QR, modes, colours, media and text.
struct CrowdPanel: View {
    @EnvironmentObject var crowd: CrowdController
    @EnvironmentObject var remote: RemoteServer
    @EnvironmentObject var engine: ShowEngine
    @EnvironmentObject var store: ShowStore

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                if let url = remote.crowdJoinURL, let qr = RemoteServer.qrImage(url) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 130, height: 130)
                    Text(url).font(.caption2.monospaced()).textSelection(.enabled)
                } else {
                    Text("Turn on the phone remote server in Control & Log.").font(.caption)
                }
                Label("\(crowd.phones) phones connected", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(crowd.phones > 0 ? .green : .secondary)
                Button("Show join QR on all screens") { showQROnScreens() }.controlSize(.small)
                Toggle("STRDM Live Cloud", isOn: $crowd.cloudEnabled).toggleStyle(.switch).controlSize(.small)
                    .help("Phones join over the internet (any Wi-Fi or 4G/5G) — no venue network needed")
                if crowd.cloudEnabled {
                    Text("Show code \(crowd.room)").font(.caption.monospaced().weight(.bold))
                    Text(crowd.cloudStatus).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("New show code") { crowd.newRoom() }.controlSize(.mini)
                }
            }
            .frame(width: 200)
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 6) {
                    ForEach(CrowdMode.allCases) { m in
                        Button { crowd.mode = m } label: {
                            Label(m.label, systemImage: m.symbol).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(crowd.mode == m ? .pink : nil)
                        .disabled((m == .image || m == .video) && !crowd.media.contains { $0.kind == (m == .video ? "video" : "image") })
                    }
                }
                HStack {
                    Text("Colours")
                    ForEach(crowd.colors.indices, id: \.self) { i in
                        ColorPicker("", selection: Binding(get: { RGB(hexString: crowd.colors[i])?.color ?? .white },
                                                           set: { crowd.colors[i] = RGB($0).hex }), supportsOpacity: false)
                            .labelsHidden()
                    }
                    Menu("Palettes") {
                        ForEach(Palette.library) { p in
                            Button(p.name) { crowd.colors = [p.a.hex, p.b.hex, p.accent.hex] }
                        }
                    }
                    .fixedSize()
                }
                HStack {
                    Text("Speed"); Slider(value: $crowd.speed, in: 0.25...4)
                    Text("Brightness"); Slider(value: $crowd.brightness, in: 0.1...1)
                }
                HStack {
                    TextField("Text on every phone (e.g. ARMANII, WIKID CITY, PUT YOUR LIGHTS UP)", text: $crowd.text)
                        .textFieldStyle(.roundedBorder)
                    Button("Show text") { crowd.mode = .text }.disabled(crowd.text.isEmpty)
                }
                HStack {
                    Button {
                        for u in pickFiles(MediaSupport.imageTypes + MediaSupport.videoTypes, multiple: true) { crowd.addMedia(from: u) }
                    } label: { Label("Add images / videos…", systemImage: "plus") }
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(crowd.media) { m in
                                Button { crowd.show(m) } label: {
                                    Label(m.name, systemImage: m.kind == "video" ? "film" : "photo")
                                }
                                .buttonStyle(.bordered)
                                .tint(crowd.currentMediaID == m.id && (crowd.mode == .image || crowd.mode == .video) ? .pink : nil)
                                .contextMenu { Button("Remove", role: .destructive) { crowd.removeMedia(m.id) } }
                            }
                        }
                    }
                }
                Text("Audience scans the QR on the venue Wi-Fi. Phones render colours and effects locally on a shared beat clock; “Follow the lights” mirrors the rig. Videos play muted. Also controllable from the STRDM Live app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func showQROnScreens() {
        guard let url = remote.crowdJoinURL, let qr = RemoteServer.qrImage(url) else { return }
        let size = NSSize(width: 1920, height: 1080)
        let artist = store.show.venue.artist
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill(); rect.fill()
            NSGradient(colors: [NSColor(red: 0.35, green: 0, blue: 0.3, alpha: 1), .black])?
                .draw(fromCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 0, toCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 1100, options: [])
            NSGraphicsContext.current?.imageInterpolation = .none
            let q: CGFloat = 640
            NSColor.white.setFill()
            NSRect(x: 160, y: (rect.height - q) / 2 - 20, width: q + 40, height: q + 40).fill()
            qr.draw(in: NSRect(x: 180, y: (rect.height - q) / 2, width: q, height: q))
            let style = NSMutableParagraphStyle(); style.alignment = .left
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 110, weight: .black), .foregroundColor: NSColor.white, .paragraphStyle: style]
            let mid: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 52, weight: .bold),
                                                      .foregroundColor: NSColor(red: 1, green: 0.3, blue: 0.7, alpha: 1), .paragraphStyle: style]
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: NSColor(white: 0.8, alpha: 1), .paragraphStyle: style]
            ("SCAN TO\nJOIN THE\nLIGHT SHOW" as NSString).draw(in: NSRect(x: 940, y: 420, width: 940, height: 400), withAttributes: big)
            ((artist.isEmpty ? "STRDM LIVE" : "\(artist.uppercased()) · STRDM LIVE") as NSString).draw(in: NSRect(x: 940, y: 330, width: 940, height: 70), withAttributes: mid)
            ("Join the venue Wi-Fi, scan, tap Join and turn brightness up" as NSString).draw(in: NSRect(x: 940, y: 250, width: 940, height: 60), withAttributes: small)
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let file = CrowdController.mediaFolder.appendingPathComponent("join-qr.png")
        try? png.write(to: file)
        var cue = Cue(kind: .video, number: "QR", name: "Crowd join QR")
        cue.videoPath = file.path
        cue.allScreens = true
        cue.fitMode = .auto
        cue.videoFade = 1
        _ = engine.fireAdHoc(cue)
    }
}
