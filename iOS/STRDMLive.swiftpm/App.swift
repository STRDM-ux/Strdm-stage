import SwiftUI
import UIKit

@main
struct STRDMLiveApp: App {
    @StateObject private var client = LiveClient()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .preferredColorScheme(.dark)
                .tint(.strdmPink)
                .onChange(of: phase) { _, p in UIApplication.shared.isIdleTimerDisabled = p == .active }
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case cues, lights, crowd, map, sound, screens, effects, crew
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cues: return "Cues"
        case .lights: return "Lights"
        case .crowd: return "Crowd"
        case .map: return "Live Map"
        case .sound: return "Sound"
        case .screens: return "Screens"
        case .effects: return "Effects"
        case .crew: return "Crew"
        }
    }
    var symbol: String {
        switch self {
        case .cues: return "list.number"
        case .lights: return "lightbulb.2.fill"
        case .crowd: return "iphone.radiowaves.left.and.right"
        case .map: return "map.fill"
        case .sound: return "slider.vertical.3"
        case .screens: return "tv.fill"
        case .effects: return "flame.fill"
        case .crew: return "checklist"
        }
    }
    @ViewBuilder var view: some View {
        switch self {
        case .cues: CuesPane()
        case .lights: LightsPane()
        case .crowd: CrowdPane()
        case .map: MapPane()
        case .sound: SoundPane()
        case .screens: ScreensPane()
        case .effects: EffectsPane()
        case .crew: CrewPane()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var client: LiveClient
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage("pane") private var pane: Pane = .cues

    var body: some View {
        Group {
            if !client.isSetUp || client.needsPIN {
                ConnectView()
            } else if hSize == .regular {
                // iPad: GO column on the left, the chosen pane on the right.
                NavigationSplitView {
                    GOPanel(large: true)
                        .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 460)
                        .toolbar(.hidden, for: .navigationBar)
                } detail: {
                    VStack(spacing: 0) {
                        Picker("", selection: $pane) {
                            ForEach(Pane.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding([.horizontal, .top], 14)
                        pane.view
                    }
                    .background(Color.black)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                // iPhone: GO panel on top of every tab.
                TabView(selection: $pane) {
                    ForEach(Pane.allCases) { p in
                        VStack(spacing: 0) {
                            GOPanel(large: false)
                            p.view
                        }
                        .background(Color.black)
                        .tabItem { Label(p.title, systemImage: p.symbol) }
                        .tag(p)
                    }
                }
            }
        }
        .onChange(of: pane) { _, p in client.pollCrowd = p == .crowd }
        .onAppear { client.pollCrowd = pane == .crowd }
    }
}
