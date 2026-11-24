import SwiftUI

/// Standby, GO, prev/next, stop / panic / effects E-STOP and what's running.
struct GOPanel: View {
    @EnvironmentObject var client: LiveClient
    let large: Bool
    @AppStorage("goLocked") private var goLocked = false
    @State private var stopArmed = false
    @State private var lastGo = Date.distantPast

    var body: some View {
        let s = client.state
        VStack(spacing: large ? 14 : 8) {
            HStack(spacing: 8) {
                Circle().fill(client.connected ? Color.goGreen : .red).frame(width: 9, height: 9)
                Image("BrandMark").resizable().frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 6))
                Text("STRDM LIVE").font(.caption.weight(.black)).tracking(2)
                    .foregroundStyle(LinearGradient(colors: [.strdmPink, .strdmPurple], startPoint: .leading, endPoint: .trailing))
                Text(s?.show ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let units = s?.sfxUnits, units > 0 {
                    Text(s?.sfxArmed == true ? "SFX ARMED" : "SFX SAFE")
                        .font(.caption2.weight(.heavy)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background((s?.sfxArmed == true ? Color.red : Color.goGreen).opacity(0.25)).clipShape(Capsule())
                }
                Text(s?.clock ?? "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            // Standby
            VStack(alignment: .leading, spacing: 3) {
                Text("STANDBY").font(.caption2.weight(.heavy)).foregroundStyle(Color.goGreen)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(s?.standby?.number ?? "–").foregroundStyle(.secondary).monospacedDigit()
                    if let k = s?.standby?.kind { Image(systemName: CueKind.symbol(k)).foregroundStyle(CueKind.color(k)) }
                    Text(s?.standby?.name ?? (s == nil ? "Connecting…" : "End of cue list")).lineLimit(1)
                }
                .font(.system(size: large ? 26 : 20, weight: .bold))
                if let n = s?.standby?.notes, !n.isEmpty { Text(n).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 16))

            // GO
            Button {
                guard !goLocked, Date().timeIntervalSince(lastGo) > 0.4 else { return }
                lastGo = Date()
                client.go()
            } label: {
                Text(goLocked ? "LOCKED" : "GO")
                    .font(.system(size: large ? 96 : 54, weight: .black))
                    .frame(maxWidth: .infinity)
                    .frame(height: large ? 220 : 110)
                    .background(goLocked ? Color(white: 0.18) : Color.goGreen)
                    .foregroundStyle(goLocked ? Color.gray : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(color: goLocked ? .clear : Color.goGreen.opacity(0.4), radius: 20, y: 8)
            }
            .buttonStyle(PressStyle())
            .contextMenu {
                Button(goLocked ? "Unlock GO" : "Lock GO (stop pocket taps)") { goLocked.toggle() }
            }

            HStack(spacing: 10) {
                bigButton("Prev", "chevron.up") { client.act("prev") }
                bigButton("Next", "chevron.down") { client.act("next") }
            }
            HStack(spacing: 10) {
                Button {
                    if stopArmed { client.act("stop"); stopArmed = false } else {
                        stopArmed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { stopArmed = false }
                    }
                } label: { tile(stopArmed ? "Tap again" : "Stop All", "stop.fill", stopArmed ? .red : Color(red: 0.3, green: 0.08, blue: 0.1)) }
                Button { client.act("panic") } label: { tile("Panic", "exclamationmark.octagon.fill", .red) }
                Button { client.act("sfxStop") } label: { tile("SFX E-STOP", "flame.fill", .red) }
            }
            .buttonStyle(PressStyle())

            if let running = s?.running, !running.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(running) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                Label("\(r.number) \(r.title)", systemImage: CueKind.symbol(r.kind)).font(.caption.weight(.semibold)).lineLimit(1)
                                ProgressView(value: r.progress ?? 1).tint(r.phase == "pre-wait" ? .orange : (r.phase == "fading" ? .cyan : Color.goGreen))
                                Text(r.remaining.map { "-" + timeString($0) } ?? timeString(r.elapsed) + " ∞")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .frame(width: 170).padding(8).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            if large { Spacer(minLength: 0) }
            if let e = client.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
        }
        .padding(large ? 18 : 12)
        .background(Color.black)
    }

    private func bigButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tile(title, icon, Color.card) }.buttonStyle(PressStyle())
    }

    private func tile(_ title: String, _ icon: String, _ bg: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: large ? 18 : 15, weight: .bold))
            .frame(maxWidth: .infinity).frame(height: large ? 60 : 46)
            .background(bg).foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.15 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
