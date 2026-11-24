import SwiftUI

/// AI Crew page: Production Manager + Creative Director, the production checklist, and one-click Autopilot.
struct CrewView: View {
    @EnvironmentObject var crew: CrewAgent
    @State private var role: CrewAgent.Role = .creative
    @State private var prompt = ""
    @State private var brief = ""
    @State private var showSettings = false

    var body: some View {
        HSplitView {
            // Left: checklist (works without AI)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Production Checklist", systemImage: "checklist").font(.headline)
                    Spacer()
                    Button("Check") { crew.runAudit() }
                    Button("Fix All") { crew.fixAll() }.buttonStyle(.borderedProminent)
                        .disabled(!crew.issues.contains { $0.fix != nil })
                }
                .padding(10)
                Divider()
                if crew.issues.isEmpty {
                    ContentUnavailableView("All clear", systemImage: "checkmark.seal.fill",
                                           description: Text("Press Check to run the show through the Production Manager's checklist."))
                } else {
                    List(crew.issues) { i in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: i.severity == .critical ? "exclamationmark.octagon.fill" : (i.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                                    .foregroundStyle(i.severity == .critical ? .red : (i.severity == .warning ? .orange : .blue))
                                Text(i.title).font(.callout.weight(.semibold))
                                Spacer()
                                Text(i.area).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(i.detail).font(.caption).foregroundStyle(.secondary)
                            if i.fix != nil {
                                Button("Fix") { crew.fix(i) }.controlSize(.small)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)

            // Right: the agents
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $role) {
                        ForEach(CrewAgent.Role.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 380)
                    Spacer()
                    if crew.canUndo {
                        Button { crew.undo() } label: { Label("Undo crew changes", systemImage: "arrow.uturn.backward") }
                    }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                .padding(10)
                // Autopilot
                HStack {
                    TextField("Brief (optional): e.g. \"WIKID CITY — pink & purple, Armanii landing in Kingston, huge finish\"", text: $brief)
                        .textFieldStyle(.roundedBorder)
                    Button { crew.autopilot(brief: brief) } label: { Label("Autopilot", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .disabled(crew.running != nil)
                        .help("Creative Director designs the show, then the Production Manager checks and fixes it")
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            let list = crew.entries.filter { $0.role == role || crew.running != nil && $0.role == crew.running }
                            if list.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(role == .creative ? "Your Creative Director" : "Your Production Manager").font(.title3.bold())
                                    Text(role == .creative
                                         ? "Designs looks, colours, lasers, effects moments and the stage set for every song, and shapes the whole night into one arc."
                                         : "Checks patch, cues, media, rig, screens, set length and safety — fixes what it can and tells you what needs hands.")
                                        .foregroundStyle(.secondary)
                                    ForEach(suggestions, id: \.self) { s in
                                        Button(s) { crew.ask(role, s) }.buttonStyle(.bordered).disabled(crew.running != nil)
                                    }
                                }
                                .padding()
                            }
                            ForEach(list) { e in bubble(e).id(e.id) }
                            if let r = crew.running {
                                HStack { ProgressView().controlSize(.small); Text("\(r.title) is working…").foregroundStyle(.secondary)
                                    Button("Stop") { crew.stop() }.controlSize(.small) }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .onChange(of: crew.entries.count) { _, _ in
                        if let last = crew.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                Divider()
                HStack {
                    TextField("Ask the \(role.title)…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                        .onSubmit(send)
                    Button("Send", action: send).buttonStyle(.borderedProminent)
                        .disabled(prompt.isEmpty || crew.running != nil)
                }
                .padding(10)
            }
            .frame(minWidth: 520)
        }
        .onAppear { crew.runAudit() }
        .sheet(isPresented: $showSettings) { CrewSettings() }
    }

    private var suggestions: [String] {
        role == .creative
            ? ["Design the whole set — every song its own identity, big finish",
               "Make the choruses hit harder and the verses calmer",
               "Pink & purple WIKID CITY look for every song",
               "Design the stage set for Armanii, a DJ, a hype man and 4 dancers"]
            : ["Run the full production check and fix what you can",
               "Is the show ready to go tonight? What's left?",
               "Make the songs play straight through with a clean end",
               "Check the set length against the slot"]
    }

    private func send() {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        crew.ask(role, t)
        prompt = ""
    }

    @ViewBuilder private func bubble(_ e: CrewAgent.Entry) -> some View {
        switch e.kind {
        case .user:
            HStack { Spacer(minLength: 80); Text(e.text).padding(10).background(Color.accentColor.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 10)) }
                .padding(.horizontal)
        case .agent:
            HStack(alignment: .top) {
                Image(systemName: e.role.symbol).foregroundStyle(e.role == .creative ? .pink : .teal)
                Text(LocalizedStringKey(e.text)).textSelection(.enabled)
                Spacer(minLength: 40)
            }
            .padding(.horizontal)
        case .action:
            Label(e.text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).padding(.horizontal, 30)
        case .error:
            Label(e.text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).padding(.horizontal)
        }
    }
}

private struct CrewSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = Keychain.apiKey ?? ""
    @State private var model = ClaudeClient.model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Crew Settings").font(.title2.bold())
            Text("The Production Manager and Creative Director run on Claude. Paste an Anthropic API key (console.anthropic.com). It's stored in your Mac's Keychain, never in show files. Usage is billed to that key.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("sk-ant-…", text: $key).textFieldStyle(.roundedBorder)
            Picker("Model", selection: $model) {
                ForEach(ClaudeClient.models, id: \.id) { Text($0.label).tag($0.id) }
            }
            Text("The checklist, Fix All and creative polish work without a key.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { Keychain.apiKey = key; ClaudeClient.model = model; dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
