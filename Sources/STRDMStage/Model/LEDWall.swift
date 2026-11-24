import Foundation
import AppKit
import SwiftUI

// MARK: - LED panels & walls (pixel mapping, processor ports, power, weight)

struct LEDPanel: Codable, Equatable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var pitch: Double          // mm
    var widthMM: Double
    var heightMM: Double
    var pxW: Int
    var pxH: Int
    var weightKg: Double
    var maxW: Double           // watts per panel, full white
    var avgW: Double           // typical show content

    static let library: [LEDPanel] = [
        .init(name: "ROE Black Pearl BP2 V2 (2.84 mm)", pitch: 2.84, widthMM: 500, heightMM: 500, pxW: 176, pxH: 176, weightKg: 9.35, maxW: 190, avgW: 65),
        .init(name: "ROE Carbon CB5 (5.77 mm)", pitch: 5.77, widthMM: 600, heightMM: 1200, pxW: 104, pxH: 208, weightKg: 13.5, maxW: 450, avgW: 150),
        .init(name: "ROE Black Onyx BO3 (3.47 mm)", pitch: 3.47, widthMM: 500, heightMM: 500, pxW: 144, pxH: 144, weightKg: 9.4, maxW: 170, avgW: 60),
        .init(name: "Absen PL2.9 Pro (2.9 mm)", pitch: 2.976, widthMM: 500, heightMM: 500, pxW: 168, pxH: 168, weightKg: 7.6, maxW: 160, avgW: 55),
        .init(name: "Absen PL3.9 Pro (3.9 mm)", pitch: 3.91, widthMM: 500, heightMM: 1000, pxW: 128, pxH: 256, weightKg: 13.5, maxW: 320, avgW: 110),
        .init(name: "INFiLED ER3.9 (3.9 mm)", pitch: 3.9, widthMM: 500, heightMM: 1000, pxW: 128, pxH: 256, weightKg: 12.5, maxW: 300, avgW: 100),
        .init(name: "Unilumin Upad IV 2.6 (2.6 mm)", pitch: 2.6, widthMM: 500, heightMM: 500, pxW: 192, pxH: 192, weightKg: 8.0, maxW: 170, avgW: 60),
        .init(name: "Generic outdoor P4.8 (4.81 mm)", pitch: 4.81, widthMM: 500, heightMM: 1000, pxW: 104, pxH: 208, weightKg: 13.0, maxW: 400, avgW: 140)
    ]
}

struct LEDWallSpec: Codable, Equatable, Hashable {
    var panelName: String = LEDPanel.library[0].name
    var cols: Int = 10
    var rows: Int = 6
    /// Pixels a processor output port can drive (Novastar 1G port ≈ 650 000 px at 8-bit).
    var pixelsPerPort: Int = 650_000
    var tenBit = false
    var voltage: Double = 230

    var panel: LEDPanel { LEDPanel.library.first { $0.name == panelName } ?? LEDPanel.library[0] }
    var panels: Int { cols * rows }
    var resolution: (w: Int, h: Int) { (cols * panel.pxW, rows * panel.pxH) }
    var sizeM: (w: Double, h: Double) { (Double(cols) * panel.widthMM / 1000, Double(rows) * panel.heightMM / 1000) }
    var portCapacity: Int { tenBit ? pixelsPerPort / 2 : pixelsPerPort }
    var panelsPerPort: Int { max(1, portCapacity / max(1, panel.pxW * panel.pxH)) }
    var ports: Int { Int((Double(panels) / Double(panelsPerPort)).rounded(.up)) }
    var weightKg: Double { Double(panels) * panel.weightKg }
    var maxWatts: Double { Double(panels) * panel.maxW }
    var avgWatts: Double { Double(panels) * panel.avgW }
    var amps: Double { maxWatts / voltage }
    /// 16 A circuits (Socapex / powerCON TRUE1 runs), loaded to 80 %.
    var circuits16A: Int { Int((amps / (16 * 0.8)).rounded(.up)) }

    /// Serpentine data chains per port, column by column (how techs usually run cables).
    func chains() -> [[(c: Int, r: Int)]] {
        var order: [(Int, Int)] = []
        for c in 0..<cols {
            let rs = c % 2 == 0 ? Array((0..<rows).reversed()) : Array(0..<rows)
            for r in rs { order.append((c, r)) }
        }
        return stride(from: 0, to: order.count, by: panelsPerPort).map { Array(order[$0..<min(order.count, $0 + panelsPerPort)]) }
    }

    /// Fit panels to a wall size in metres.
    static func fitting(widthM: Double, heightM: Double, panel: LEDPanel) -> LEDWallSpec {
        var s = LEDWallSpec()
        s.panelName = panel.name
        s.cols = max(1, Int((widthM * 1000 / panel.widthMM).rounded()))
        s.rows = max(1, Int((heightM * 1000 / panel.heightMM).rounded()))
        return s
    }
}

enum PixelMap {
    static let portColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink,
                                        .systemBrown, .systemMint, .systemIndigo, .systemCyan]

    /// Processor test image at the wall's native resolution: each panel outlined and numbered,
    /// colour = output port, arrows = data direction, plus a centre circle and resolution text.
    static func image(_ spec: LEDWallSpec, name: String) -> NSImage {
        let (w, h) = spec.resolution
        let pw = CGFloat(spec.panel.pxW), ph = CGFloat(spec.panel.pxH)
        return NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
            NSColor.black.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
            let fontSize = max(10, min(pw, ph) / 6)
            for (portIndex, chain) in spec.chains().enumerated() {
                let col = portColors[portIndex % portColors.count]
                for (k, cell) in chain.enumerated() {
                    let r = NSRect(x: CGFloat(cell.c) * pw, y: CGFloat(cell.r) * ph, width: pw, height: ph)
                    col.withAlphaComponent(0.55).setFill(); r.fill()
                    NSColor.white.setStroke()
                    let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1; path.stroke()
                    let txt = "P\(portIndex + 1)·\(k + 1)\nC\(cell.c + 1) R\(cell.r + 1)" as NSString
                    let style = NSMutableParagraphStyle(); style.alignment = .center
                    txt.draw(in: r.insetBy(dx: 2, dy: ph / 2 - fontSize * 1.2),
                             withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: style])
                    // data direction
                    if k + 1 < chain.count {
                        let n = chain[k + 1]
                        let a = NSPoint(x: r.midX, y: r.midY), b = NSPoint(x: CGFloat(n.c) * pw + pw / 2, y: CGFloat(n.r) * ph + ph / 2)
                        NSColor.white.withAlphaComponent(0.8).setStroke()
                        let l = NSBezierPath(); l.move(to: a); l.line(to: NSPoint(x: a.x + (b.x - a.x) * 0.45, y: a.y + (b.y - a.y) * 0.45)); l.lineWidth = 2; l.stroke()
                    }
                }
            }
            NSColor.white.setStroke()
            let circle = NSBezierPath(ovalIn: NSRect(x: CGFloat(w) / 2 - CGFloat(h) * 0.4, y: CGFloat(h) * 0.1, width: CGFloat(h) * 0.8, height: CGFloat(h) * 0.8))
            circle.lineWidth = 3; circle.stroke()
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: 0, y: 0)); cross.line(to: NSPoint(x: w, y: h))
            cross.move(to: NSPoint(x: w, y: 0)); cross.line(to: NSPoint(x: 0, y: h))
            NSColor.white.withAlphaComponent(0.35).setStroke(); cross.lineWidth = 2; cross.stroke()
            let label = "\(name) — \(w)×\(h) px — \(spec.cols)×\(spec.rows) \(spec.panel.name) — \(spec.ports) port\(spec.ports == 1 ? "" : "s")" as NSString
            let style = NSMutableParagraphStyle(); style.alignment = .center
            label.draw(in: NSRect(x: 0, y: CGFloat(h) / 2 - fontSize, width: CGFloat(w), height: fontSize * 2.4),
                       withAttributes: [.font: NSFont.systemFont(ofSize: fontSize * 1.4, weight: .heavy), .foregroundColor: NSColor.white,
                                        .backgroundColor: NSColor.black.withAlphaComponent(0.6), .paragraphStyle: style])
            return true
        }
    }

    static func png(_ spec: LEDWallSpec, name: String) -> Data? {
        let img = image(spec, name: name)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func save(_ spec: LEDWallSpec, name: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("STRDM Stage Shows/Pixel Maps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")) pixel map.png")
        guard let d = png(spec, name: name), (try? d.write(to: url)) != nil else { return nil }
        return url
    }
}

// MARK: - AutoCAD DXF export of the stage plot

enum DXFExporter {
    /// ASCII DXF (R12) in metres: stage edge, every item as a closed outline on its own layer, with labels.
    static func dxf(_ plot: StagePlot) -> String {
        var out = ["0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "6", "0", "ENDSEC",
                   "0", "SECTION", "2", "ENTITIES"]
        func line(_ layer: String, _ a: CGPoint, _ b: CGPoint) {
            out += ["0", "LINE", "8", layer, "10", f(a.x), "20", f(a.y), "30", "0", "11", f(b.x), "21", f(b.y), "31", "0"]
        }
        func text(_ layer: String, _ p: CGPoint, _ s: String, _ h: Double) {
            out += ["0", "TEXT", "8", layer, "10", f(p.x), "20", f(p.y), "30", "0", "40", f(h), "1", s.replacingOccurrences(of: "\n", with: " ")]
        }
        func rect(_ layer: String, cx: Double, cy: Double, w: Double, d: Double, rot: Double) {
            let r = rot * .pi / 180
            let corners = [(-w / 2, -d / 2), (w / 2, -d / 2), (w / 2, d / 2), (-w / 2, d / 2)].map { (x, y) in
                CGPoint(x: cx + x * cos(r) - y * sin(r), y: cy + x * sin(r) + y * cos(r))
            }
            for i in 0..<4 { line(layer, corners[i], corners[(i + 1) % 4]) }
        }
        rect("STAGE_EDGE", cx: plot.stageWidth / 2, cy: plot.stageDepth / 2, w: plot.stageWidth, d: plot.stageDepth, rot: 0)
        text("STAGE_EDGE", CGPoint(x: plot.stageWidth / 2 - 2, y: -0.8), "AUDIENCE / FOH", 0.3)
        for it in plot.items {
            let layer = it.kind.rawValue.uppercased()
            rect(layer, cx: it.x, cy: it.y, w: it.width, d: it.depth, rot: -it.rotation)
            text(layer, CGPoint(x: it.x - it.width / 2 + 0.05, y: it.y), it.label + (it.topHeight > 0 ? " (h \(f(it.topHeight)) m)" : ""), 0.12)
        }
        out += ["0", "ENDSEC", "0", "EOF"]
        return out.joined(separator: "\n")
    }

    private static func f(_ v: Double) -> String { String(format: "%.3f", v) }

    @MainActor
    static func export(_ show: Show) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "dxf") ?? .data]
        panel.nameFieldStringValue = "\(show.venue.artist.isEmpty ? show.name : show.venue.artist) stage plot.dxf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? dxf(show.stagePlot).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Inspector section for LED walls

struct LEDWallInspector: View {
    @Binding var item: StageItem
    @EnvironmentObject var engine: ShowEngine

    var body: some View {
        let spec = item.led ?? LEDWallSpec.fitting(widthM: item.width, heightM: item.topHeight > 0 ? min(item.topHeight, 8) : 3, panel: LEDPanel.library[0])
        Section("LED wall — pixel map") {
            Picker("Panel", selection: Binding(get: { spec.panelName }, set: { name in
                let p = LEDPanel.library.first { $0.name == name } ?? LEDPanel.library[0]
                var s = LEDWallSpec.fitting(widthM: item.width, heightM: spec.sizeM.h, panel: p)
                s.tenBit = spec.tenBit
                item.led = s
            })) { ForEach(LEDPanel.library) { Text($0.name).tag($0.name) } }
            Stepper("Columns: \(spec.cols)", value: Binding(get: { spec.cols }, set: { v in var s = spec; s.cols = max(1, v); item.led = s; item.width = s.sizeM.w }), in: 1...200)
            Stepper("Rows: \(spec.rows)", value: Binding(get: { spec.rows }, set: { v in var s = spec; s.rows = max(1, v); item.led = s; item.height = s.sizeM.h + (item.elevation ?? 0) }), in: 1...100)
            Toggle("10-bit colour (halves port capacity)", isOn: Binding(get: { spec.tenBit }, set: { v in var s = spec; s.tenBit = v; item.led = s }))
            LabeledContent("Size") { Text(String(format: "%.2f × %.2f m", spec.sizeM.w, spec.sizeM.h)) }
            LabeledContent("Resolution") { Text("\(spec.resolution.w) × \(spec.resolution.h) px").monospacedDigit() }
            LabeledContent("Panels") { Text("\(spec.panels)  ·  \(spec.panelsPerPort) per port") }
            LabeledContent("Processor ports") { Text("\(spec.ports)") }
            LabeledContent("Weight") { Text(String(format: "%.0f kg", spec.weightKg)) }
            LabeledContent("Power") { Text(String(format: "%.1f kW max · %.1f kW typical · %d × 16 A", spec.maxWatts / 1000, spec.avgWatts / 1000, spec.circuits16A)) }
            HStack {
                Button("Send pixel map to screens") {
                    if let url = PixelMap.save(spec, name: item.label) {
                        var cue = Cue(kind: .video, number: "PX", name: "Pixel map — \(item.label)")
                        cue.videoPath = url.path; cue.allScreens = true; cue.fitMode = .stretch
                        _ = engine.fireAdHoc(cue)
                    }
                }
                Button("Save PNG") { if let url = PixelMap.save(spec, name: item.label) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
            .onAppear { if item.led == nil { item.led = spec } }
        }
    }
}

// MARK: - Live 3D client pitch links

@MainActor
enum PitchPublisher {
    /// Uploads the stage design to STRDM Live Cloud and returns a link anyone can open to orbit it in 3D.
    static func publish(show: Show, cloudURL: String, logo: String?) async -> URL? {
        let p = show.stagePlot
        let palette = show.lightShows.first.map { Palette.named($0.paletteName) }
        let colors = palette.map { [$0.a.hex, $0.b.hex, $0.accent.hex] } ?? ["#FF3D81", "#00E5FF", "#FFFFFF"]
        let artist = show.venue.artist.isEmpty ? show.name : show.venue.artist
        var subtitle = [show.venue.tourName, show.venue.venueName, show.venue.city].filter { !$0.isEmpty }.joined(separator: " · ")
        subtitle += (subtitle.isEmpty ? "" : " — ") + String(format: "%.0f × %.0f m stage", p.stageWidth, p.stageDepth)
        var obj: [String: Any] = [
            "title": artist, "artist": artist, "subtitle": subtitle,
            "width": p.stageWidth, "depth": p.stageDepth, "deck": p.deck, "colors": colors,
            "items": p.items.map { it -> [String: Any] in
                ["kind": it.kind.rawValue, "label": it.label, "x": it.x, "y": it.y, "width": it.width, "depth": it.depth,
                 "height": it.topHeight, "elevation": it.elevation ?? 0, "rotation": it.rotation]
            },
            "fixtures": show.lighting.fixtures.compactMap { f -> [String: Any]? in
                guard let x = f.stageX, let y = f.stageY else { return nil }
                return ["x": x, "y": y, "z": f.stageZ ?? 7, "mover": f.profile.channels.contains { $0.kind == .pan }]
            }
        ]
        if let logo { obj["logo"] = logo }
        guard let body = try? JSONSerialization.data(withJSONObject: obj), let url = URL(string: "\(cloudURL)/api/pitch") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (d, resp) = try? await URLSession.shared.upload(for: req, from: body), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["url"] as? String else { return nil }
        return URL(string: s)
    }
}
