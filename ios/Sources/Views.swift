import SwiftUI

@main
struct EarshotApp: App {
    @StateObject private var brain = Brain.shared
    @StateObject private var rig = AudioRig.shared
    @StateObject private var ear = Whisperer.shared
    // `-startTab map` on launch picks the first tab (testing).
    @State private var tab = UserDefaults.standard.string(forKey: "startTab") ?? "live"

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                LiveView().tabItem { Label("Live", systemImage: "waveform") }.tag("live")
                MapView().tabItem { Label("Map", systemImage: "point.3.connected.trianglepath.dotted") }.tag("map")
                PeopleView().tabItem { Label("People", systemImage: "person.2") }.tag("people")
                SetupView().tabItem { Label("Setup", systemImage: "gearshape") }.tag("setup")
            }
            .environmentObject(brain)
            .environmentObject(brain.listener)
            .environmentObject(rig)
            .environmentObject(ear)
            .tint(.indigo)
            .task { await brain.boot() }
            .onChange(of: rig.generation) { _, _ in
                Task { await brain.listener.restartIfRunning() }
            }
        }
    }
}

// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var brain: Brain
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var rig: AudioRig

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusRow
                    talkingCard
                    controls
                    if !listener.partial.isEmpty {
                        Text(listener.partial)
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                    }
                    if let w = brain.whispers.first {
                        whisperCard(w)
                    }
                    transcript
                }
                .padding(16)
            }
            .navigationTitle("Earshot")
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                pill(listener.running ? "Listening" : "Paused", listener.running ? .green : .gray, "mic.fill")
                pill(rig.privateOutput ? "AirPods" : "No earbuds", rig.privateOutput ? .indigo : .orange,
                     rig.privateOutput ? "airpods" : "speaker.slash.fill")
                pill(brain.backendOK == true ? "Online" : (brain.backendOK == nil ? "…" : "Offline"),
                     brain.backendOK == true ? .teal : .red, "server.rack")
                Spacer()
            }
            LevelBar(level: listener.level).frame(height: 4)
            if let p = listener.problem ?? brain.lastError ?? rig.error {
                Text(p).font(.footnote).foregroundStyle(.red)
            }
            if !brain.wearerEnrolled && brain.backendOK == true {
                Text("Record your voice in Setup so Earshot can tell you apart from everyone else.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if !rig.privateOutput {
                Text("Connect AirPods to hear whispers. Earshot never speaks out loud.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var talkingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TALKING TO").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if let p = brain.talkingTo {
                Text(p.name).font(.title.bold())
                Text(p.headline).foregroundStyle(.secondary)
                ForEach(p.followups.prefix(2), id: \.self) { f in
                    Label(f, systemImage: "arrow.turn.down.right").font(.footnote)
                }
            } else if let u = brain.talkingToUnknown {
                Text("New voice").font(.title.bold())
                Text("\(u) · waiting for a name").foregroundStyle(.secondary)
            } else {
                Text("No one yet").font(.title.bold()).foregroundStyle(.tertiary)
                Text("Start a conversation. Introductions are saved automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.indigo.opacity(0.10), in: .rect(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { Task { await brain.toggleListening() } } label: {
                Label(listener.running ? "Pause" : "Listen", systemImage: listener.running ? "pause.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            Button { Task { await brain.whoIsThis() } } label: {
                Label("Who?", systemImage: "person.wave.2").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
            Button { brain.startQuestion() } label: {
                Label(brain.awaitingQuestion ? "Listening…" : "Ask", systemImage: "questionmark.bubble")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }
        .controlSize(.large)
        .overlay(alignment: .bottomTrailing) {
            if brain.session != nil {
                Button("End session") { Task { await brain.endSession() } }
                    .font(.caption).offset(y: 30)
            }
        }
        .padding(.bottom, brain.session != nil ? 18 : 0)
    }

    private func whisperCard(_ w: Brain.Whisper) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: w.spoken ? "ear.fill" : "ear.trianglebadge.exclamationmark")
                .foregroundStyle(w.spoken ? .indigo : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.text).font(.callout)
                Text(w.spoken ? "whispered" : "not spoken: no earbuds")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(brain.lines.reversed()) { l in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(color(l.kind)).frame(width: 8, height: 8).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(l.who).font(.caption.weight(.semibold))
                            if l.match > 0 {
                                Text("voice \(Int((l.match * 100).rounded()))%")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                        Text(l.text).font(.subheadline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ kind: String) -> Color {
        switch kind {
        case "me": return .gray
        case "person": return .indigo
        default: return .orange
        }
    }

    private func pill(_ t: String, _ c: Color, _ icon: String) -> some View {
        Label(t, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(c.opacity(0.15), in: .capsule)
            .foregroundStyle(c)
    }
}

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green.gradient)
                    .frame(width: g.size.width * CGFloat(min(1, sqrt(Double(level)) * 3)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }
}

// MARK: - People

struct PeopleView: View {
    @State private var people: [Person] = []
    @State private var error: String?
    @State private var query = ""

    var filtered: [Person] {
        guard !query.isEmpty else { return people }
        let q = query.lowercased()
        return people.filter { ($0.name + $0.role + $0.org + $0.facts.joined()).lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(filtered) { p in
                    NavigationLink(value: p) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.name).font(.headline)
                                if p.has_voice { Image(systemName: "waveform").font(.caption).foregroundStyle(.indigo) }
                            }
                            Text(p.headline).font(.subheadline).foregroundStyle(.secondary)
                            Text("Met \(p.times_met)× · last \(Date(timeIntervalSince1970: p.last_seen).formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                if people.isEmpty && error == nil {
                    Text("Nobody yet. Everyone who introduces themselves shows up here.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query)
            .navigationTitle("People")
            .navigationDestination(for: Person.self) { p in PersonView(person: p) { await load() } }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    func load() async {
        do { people = try await API.people(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct PersonView: View {
    @State var person: Person
    let changed: () async -> Void
    @State private var said: [Said] = []
    @State private var newFact = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Who") {
                TextField("Name", text: $person.name)
                TextField("Role", text: $person.role)
                TextField("Org", text: $person.org)
            }
            Section("Remember") {
                ForEach(person.facts, id: \.self) { Text($0) }
                    .onDelete { person.facts.remove(atOffsets: $0) }
                HStack {
                    TextField("Add a note", text: $newFact)
                    Button("Add") {
                        let f = newFact.trimmingCharacters(in: .whitespaces)
                        if !f.isEmpty { person.facts.append(f); newFact = "" }
                    }
                }
            }
            if !person.followups.isEmpty {
                Section("Follow up") {
                    ForEach(person.followups, id: \.self) { Text($0) }
                        .onDelete { person.followups.remove(atOffsets: $0) }
                }
            }
            Section("Voice") {
                LabeledContent("Voiceprint", value: person.has_voice ? "\(person.voice_samples) samples" : "none")
                LabeledContent("First met", value: Date(timeIntervalSince1970: person.first_met).formatted(date: .abbreviated, time: .shortened))
            }
            if !said.isEmpty {
                Section("What they said") {
                    ForEach(said, id: \.self) { s in
                        VStack(alignment: .leading) {
                            Text(s.text).font(.subheadline)
                            Text(Date(timeIntervalSince1970: s.ts).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section {
                Button("Forget \(person.name)", role: .destructive) {
                    Task { try? await API.delete(person.id); await changed(); dismiss() }
                }
            }
        }
        .navigationTitle(person.name)
        .toolbar {
            Button("Save") { Task { if let p = try? await API.update(person) { person = p }; await changed() } }
        }
        .task { said = (try? await API.person(person.id).said) ?? [] }
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var brain: Brain
    @EnvironmentObject var rig: AudioRig
    @EnvironmentObject var ear: Whisperer
    @State private var base = API.base
    @State private var enrolling = false
    @State private var enrollMsg = ""
    @State private var progress = 0.0
    @AppStorage("autoListen") private var autoListen = true

    private let script = "I'm recording my own voice so Earshot knows when I'm the one talking. The quick brown fox jumps over the lazy dog, and I'm looking forward to meeting new people tonight."

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(script).font(.callout).foregroundStyle(enrolling ? .primary : .secondary)
                    if enrolling { ProgressView(value: progress) }
                    Button(enrolling ? "Keep reading…" : (brain.wearerEnrolled ? "Re-record my voice" : "Record my voice")) {
                        Task { await enroll() }
                    }.disabled(enrolling)
                    if !enrollMsg.isEmpty { Text(enrollMsg).font(.footnote) }
                } header: { Text("Your voice") } footer: {
                    Text("Read the text out loud for 12 seconds in a quiet spot. Earshot uses it to ignore you and only learn other people.")
                }
                Section("Whispers") {
                    LabeledContent("Route", value: rig.route).font(.footnote)
                    VStack(alignment: .leading) {
                        Text("Volume").font(.footnote)
                        Slider(value: $ear.volume, in: 0.1...1)
                    }
                    VStack(alignment: .leading) {
                        Text("Speed").font(.footnote)
                        Slider(value: $ear.rate, in: 0.4...0.62)
                    }
                    Button("Test whisper") { brain.whisper("That's Maya Chen, product manager at Stripe. She's hiring interns.", interrupt: true) }
                }
                Section {
                    Toggle("Start listening on launch", isOn: $autoListen)
                } footer: {
                    Text("AirPods: press once for “who is this?”, press twice to ask a question. Keep the iPhone in a chest or jacket pocket, mic side up, for the best pickup.")
                }
                Section("Backend") {
                    TextField("URL", text: $base)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onSubmit { save() }
                    HStack {
                        Button("Save & test") { save() }
                        Spacer()
                        Text(brain.backendOK == true ? "Connected" : (brain.backendOK == nil ? "" : "Unreachable"))
                            .font(.footnote).foregroundStyle(brain.backendOK == true ? .green : .red)
                    }
                    Button("Use my Mac (default)") { base = API.defaultBase; save() }
                }
            }
            .navigationTitle("Setup")
        }
    }

    func save() {
        API.base = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        base = API.base
        Task { await brain.checkBackend() }
    }

    func enroll() async {
        enrolling = true
        enrollMsg = ""
        progress = 0
        let t = Task { @MainActor in
            for i in 1...120 { try? await Task.sleep(for: .milliseconds(100)); progress = Double(i) / 120 }
        }
        enrollMsg = await brain.enroll(seconds: 12, reset: !brain.wearerEnrolled)
        t.cancel()
        enrolling = false
    }
}
