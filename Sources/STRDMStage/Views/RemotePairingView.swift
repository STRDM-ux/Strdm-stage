import SwiftUI

/// Shown in Control & Log: QR code + PIN to pair the iPhone remote.
struct RemotePairingSection: View {
    @EnvironmentObject var remote: RemoteServer

    var body: some View {
        Section("Phone & iPad Remote — STRDM Live") {
            Toggle("Allow phone remote on this network", isOn: $remote.enabled)
            if remote.enabled {
                HStack(alignment: .top, spacing: 16) {
                    if let url = remote.pairingURL, let qr = RemoteServer.qrImage(url) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 150, height: 150)
                            .padding(6)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Put the phone or iPad on the same Wi-Fi as this Mac.")
                        Text("2. Scan the QR code with its camera.")
                        Text("3. In Safari tap Share → Add to Home Screen — it opens as the STRDM Live app.")
                        HStack {
                            Text("PIN").foregroundStyle(.secondary)
                            Text(remote.pin).font(.system(.title2, design: .monospaced).weight(.bold))
                            Button("New PIN") { remote.newPIN() }
                                .help("Kicks out every phone that's currently connected")
                        }
                        HStack(spacing: 6) {
                            Circle().fill(remote.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(remote.isRunning ? "Listening on port \(remote.port)" : "Not running")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(remote.connectedDevices.isEmpty ? "No phones connected"
                             : "Connected: " + remote.connectedDevices.joined(separator: ", "))
                            .font(.caption).foregroundStyle(remote.connectedDevices.isEmpty ? Color.secondary : Color.green)
                    }
                }
                ForEach(remote.addresses, id: \.self) { url in
                    HStack {
                        Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(url)/?t=\(remote.pin)", forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    Button("Refresh addresses") { remote.refreshAddresses() }
                    Button("Restart server") { remote.start() }
                }
                if let error = remote.error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Venue Wi-Fi blocking phones from talking to each other? Use your own router or the Mac's Personal Hotspot instead. The .local address keeps working when the Mac's IP changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
