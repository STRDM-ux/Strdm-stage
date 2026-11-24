import SwiftUI
import VisionKit

struct ConnectView: View {
    @EnvironmentObject var client: LiveClient
    @State private var address = ""
    @State private var pinText = ""
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Image("BrandMark").resizable().scaledToFit().frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                        .shadow(color: .strdmPurple.opacity(0.5), radius: 24)
                    Text("STRDM LIVE")
                        .font(.system(size: 40, weight: .black)).tracking(6)
                        .foregroundStyle(LinearGradient(colors: [.strdmPink, .strdmPurple], startPoint: .leading, endPoint: .trailing))
                    Text("Control · show control for STRDM Stage").foregroundStyle(.secondary)
                }
                .padding(.top, 50)

                if client.baseURL != nil && client.needsPIN {
                    pinCard
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Macs on this Wi-Fi", systemImage: "desktopcomputer").font(.headline)
                        if client.found.isEmpty {
                            HStack { ProgressView(); Text("Looking for STRDM Stage…").foregroundStyle(.secondary) }
                        }
                        ForEach(client.found) { mac in
                            Button { client.connect(to: mac) } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer").font(.title2)
                                    Text(mac.name).font(.title3.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding().background(Color.card).clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if DataScannerViewController.isSupported {
                        Button { scanning = true } label: {
                            Label("Scan pairing QR", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or type the address shown on the Mac").font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            TextField("192.168.1.20:8686", text: $address)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            Button("Connect") { _ = client.pair(with: address) }.buttonStyle(.bordered).disabled(address.isEmpty)
                        }
                    }
                    Text("On the Mac: Control & Log → Phone & iPad Remote. Both devices must be on the same Wi-Fi.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $scanning) {
            QRScanner { text in
                scanning = false
                _ = client.pair(with: text)
            }
            .ignoresSafeArea()
        }
    }

    private var pinCard: some View {
        VStack(spacing: 14) {
            Text("Enter the 4-digit PIN shown on the Mac").font(.headline)
            TextField("PIN", text: $pinText)
                .keyboardType(.numberPad)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 200)
                .padding(10).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 14))
            Button {
                client.pin = pinText
                client.needsPIN = false
            } label: { Text("Connect").frame(width: 200).padding(.vertical, 6) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(pinText.count < 4)
            Button("Choose another Mac") { client.forget() }.font(.footnote)
        }
    }
}

/// Live camera QR reader (VisionKit).
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .fast, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case let .barcode(code) = item, let s = code.payloadStringValue, s.lowercased().hasPrefix("http") {
                    done = true
                    scanner.stopScanning()
                    onCode(s)
                    return
                }
            }
        }
    }
}
