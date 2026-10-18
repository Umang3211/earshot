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
                MapView().tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }.tag("map")
                PeopleView().tabItem { Label("People", systemImage: "person.2") }.tag("people")
                SetupView().tabItem { Label("Setup", systemImage: "slider.horizontal.3") }.tag("setup")
            }
            .environmentObject(brain)
            .environmentObject(brain.listener)
            .environmentObject(rig)
            .environmentObject(ear)
            .tint(ES.accent)
            .preferredColorScheme(.dark)
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
        ZStack {
            Atmosphere()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    topBar
                    hero
                    SoundField(level: listener.level, active: listener.running)
                        .frame(height: 74)
                        .padding(.horizontal, -4)
                    if let w = brain.whispers.first { whisperCard(w) }
                    controls
                    notices
                    if !listener.partial.isEmpty {
                        Text(listener.partial)
                            .font(.system(size: 15)).foregroundStyle(ES.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16).contentCard()
                    }
                    transcript
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("earshot")
                .font(ES.display(22, .heavy)).tracking(-0.8)
                .foregroundStyle(ES.text)
            Spacer()
            StatusDot(label: listener.running ? "Live" : "Paused",
                      color: listener.running ? ES.green : ES.text3, pulsing: listener.running)
            StatusDot(label: rig.privateOutput ? "AirPods" : "No buds",
                      color: rig.privateOutput ? ES.accent : ES.amber)
            if brain.backendOK != true {
                StatusDot(label: "Offline", color: ES.pink)
            }
        }
        .padding(.top, 6)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let p = brain.talkingTo {
                Eyebrow(text: "Talking to")
                HStack(alignment: .center, spacing: 14) {
                    Monogram(name: p.name, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(ES.display(34)).tracking(-1.0).foregroundStyle(ES.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(p.headline).font(.system(size: 16)).foregroundStyle(ES.text2)
                    }
                }
                if !p.followups.isEmpty {
                    FlowChips(items: Array(p.followups.prefix(2)))
                }
            } else if let u = brain.talkingToUnknown {
                Eyebrow(text: "New voice · \(u)")
                Text("Listening for\ntheir name.").font(ES.display(38)).tracking(-1.2).foregroundStyle(ES.text)
            } else {
                Eyebrow(text: listener.running ? "Listening" : "Ready")
                Text(listener.running ? "Say hi to\nsomeone new." : "Your network,\nin your ear.")
                    .font(ES.display(38)).tracking(-1.2).foregroundStyle(ES.text)
                Text("Introductions are saved by voice. Next time, Earshot whispers who they are.")
                    .font(.system(size: 15)).foregroundStyle(ES.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(duration: 0.4), value: brain.talkingTo?.id)
    }

    private func whisperCard(_ w: Brain.Whisper) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: w.spoken ? "ear.fill" : "ear.trianglebadge.exclamationmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(w.spoken ? ES.accent : ES.amber)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: w.spoken ? "In your ear" : "Not spoken · no AirPods")
                Text(w.text).font(.system(size: 16, weight: .medium)).foregroundStyle(ES.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard()
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button { Task { await brain.toggleListening() } } label: {
                Label(listener.running ? "Pause listening" : "Start listening",
                      systemImage: listener.running ? "pause.fill" : "waveform")
            }
            .buttonStyle(GlossyButtonStyle())
            HStack(spacing: 10) {
                Button { Task { await brain.whoIsThis() } } label: {
                    Label("Who is this?", systemImage: "person.wave.2")
                }
                Button { brain.startQuestion() } label: {
                    Label(brain.awaitingQuestion ? "Listening…" : "Ask", systemImage: "sparkle")
                }
            }
            .buttonStyle(PillButtonStyle())
            if brain.session != nil {
                Button("End session") { Task { await brain.endSession() } }
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(ES.text3)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        let lines = [
            listener.problem, brain.lastError, rig.error,
            (!brain.wearerEnrolled && brain.backendOK == true) ? "Record your voice in Setup so Earshot can tell you apart." : nil,
            !rig.privateOutput ? "Connect AirPods to hear whispers. Earshot never speaks out loud." : nil,
        ].compactMap { $0 }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { l in
                    Label(l, systemImage: "info.circle")
                        .font(.system(size: 13)).foregroundStyle(ES.text3)
                }
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if !brain.lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "Conversation").padding(.bottom, 10)
                ForEach(Array(brain.lines.reversed().enumerated()), id: \.element.id) { i, l in
                    HStack(alignment: .top, spacing: 12) {
                        if l.kind == "me" {
                            Image(systemName: "person.fill").font(.system(size: 13))
                                .foregroundStyle(ES.text3)
                                .frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.06)))
                        } else if l.kind == "person" {
                            Monogram(name: l.who, size: 30)
                        } else {
                            Image(systemName: "waveform").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ES.amber)
                                .frame(width: 30, height: 30).background(Circle().fill(ES.amber.opacity(0.12)))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(l.who).font(.system(size: 14, weight: .semibold)).foregroundStyle(ES.text)
                                if l.match > 0 {
                                    Text("\(Int((l.match * 100).rounded()))% voice")
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundStyle(ES.text3)
                                }
                                Spacer()
                                Text(l.at, style: .time).font(.system(size: 11)).foregroundStyle(ES.text3)
                            }
                            Text(l.text).font(.system(size: 15)).foregroundStyle(ES.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                    if i < brain.lines.count - 1 { Divider().overlay(ES.hairline) }
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
            .contentCard(radius: ES.frame)
        }
    }
}

struct FlowChips: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { f in
                Label(f, systemImage: "arrow.turn.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ES.accent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(ES.accent.opacity(0.12)))
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
            ZStack {
                Atmosphere()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow(text: "\(people.count) \(people.count == 1 ? "person" : "people")")
                            Text("People you've met.").font(ES.display(34)).tracking(-1.1).foregroundStyle(ES.text)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(ES.text3)
                            TextField("", text: $query, prompt: Text("Search names, companies, notes").foregroundStyle(ES.text3))
                                .foregroundStyle(ES.text)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        .padding(.horizontal, 16).frame(height: 48)
                        .glassPill()
                        if let error { Text(error).font(.system(size: 13)).foregroundStyle(ES.pink) }
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { p in
                                NavigationLink(value: p) { PersonRow(person: p) }.buttonStyle(.plain)
                            }
                        }
                        if people.isEmpty && error == nil {
                            Text("Nobody yet. Everyone who introduces themselves shows up here.")
                                .font(.system(size: 15)).foregroundStyle(ES.text2)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .refreshable { await load() }
            }
            .navigationDestination(for: Person.self) { p in PersonView(person: p) { await load() } }
            .task { await load() }
        }
    }

    func load() async {
        do { people = try await API.people(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct PersonRow: View {
    let person: Person
    var body: some View {
        HStack(spacing: 14) {
            Monogram(name: person.name, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(ES.text)
                Text(person.headline).font(.system(size: 14)).foregroundStyle(ES.text2).lineLimit(1)
                HStack(spacing: 6) {
                    if person.has_voice {
                        Image(systemName: "waveform").font(.system(size: 10, weight: .bold)).foregroundStyle(ES.accent)
                    }
                    Text("Met \(person.times_met)× · \(Date(timeIntervalSince1970: person.last_seen).formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundStyle(ES.text3)
                }
            }
            Spacer(minLength: 0)
            if !person.followups.isEmpty {
                Circle().fill(ES.amber).frame(width: 8, height: 8)
            }
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ES.text3)
        }
        .padding(14)
        .contentCard()
        .contentShape(Rectangle())
    }
}

struct PersonView: View {
    @State var person: Person
    let changed: () async -> Void
    @State private var said: [Said] = []
    @State private var newFact = ""
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Atmosphere()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Monogram(name: person.name, size: 72)
                        if editing {
                            field("Name", $person.name)
                            field("Role", $person.role)
                            field("Company", $person.org)
                        } else {
                            Text(person.name).font(ES.display(36)).tracking(-1.2).foregroundStyle(ES.text)
                            Text(person.headline).font(.system(size: 17)).foregroundStyle(ES.text2)
                        }
                        HStack(spacing: 8) {
                            stat("\(person.times_met)×", "met")
                            stat(person.has_voice ? "\(person.voice_samples)" : "—", "voice samples")
                            stat(Date(timeIntervalSince1970: person.first_met).formatted(.dateTime.month(.abbreviated).day()), "first met")
                        }
                    }
                    if !person.followups.isEmpty {
                        section("Follow up") {
                            ForEach(person.followups, id: \.self) { f in
                                bullet(f, color: ES.amber)
                            }
                        }
                    }
                    section("Remember") {
                        ForEach(person.facts, id: \.self) { f in
                            HStack { bullet(f, color: ES.accent)
                                if editing {
                                    Button { person.facts.removeAll { $0 == f } } label: {
                                        Image(systemName: "minus.circle.fill").foregroundStyle(ES.pink)
                                    }
                                }
                            }
                        }
                        HStack {
                            TextField("", text: $newFact, prompt: Text("Add a note").foregroundStyle(ES.text3))
                                .foregroundStyle(ES.text)
                            Button("Add") {
                                let f = newFact.trimmingCharacters(in: .whitespaces)
                                if !f.isEmpty { person.facts.append(f); newFact = ""; save() }
                            }
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(ES.accent)
                        }
                        .padding(.top, 4)
                    }
                    if !said.isEmpty {
                        section("What they said") {
                            ForEach(said, id: \.self) { s in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("“\(s.text)”").font(.system(size: 15)).foregroundStyle(ES.text2)
                                    Text(Date(timeIntervalSince1970: s.ts).formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11)).foregroundStyle(ES.text3)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        Task { try? await API.delete(person.id); await changed(); dismiss() }
                    } label: {
                        Text("Forget \(person.name)").foregroundStyle(ES.pink)
                    }
                    .buttonStyle(PillButtonStyle())
                    .padding(.top, 6)
                }
                .padding(.horizontal, 20).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar {
            Button(editing ? "Done" : "Edit") {
                if editing { save() }
                editing.toggle()
            }
        }
        .task { said = (try? await API.person(person.id).said) ?? [] }
    }

    private func save() {
        Task { if let p = try? await API.update(person) { person = p }; await changed() }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(label).foregroundStyle(ES.text3))
            .font(.system(size: 17)).foregroundStyle(ES.text)
            .padding(.horizontal, 14).frame(height: 46)
            .background(ES.raised, in: .rect(cornerRadius: ES.control))
            .overlay(RoundedRectangle(cornerRadius: ES.control).strokeBorder(ES.hairline))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(ES.text)
            Text(label).font(.system(size: 11)).foregroundStyle(ES.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .contentCard(radius: ES.control)
    }

    private func bullet(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color).frame(width: 6, height: 6).offset(y: -2)
            Text(text).font(.system(size: 15)).foregroundStyle(ES.text)
            Spacer(minLength: 0)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .contentCard()
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
        ZStack {
            Atmosphere()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Setup").font(ES.display(34)).tracking(-1.1).foregroundStyle(ES.text)
                        .padding(.top, 8)

                    card("Your voice", brain.wearerEnrolled ? "Recorded" : "Not recorded yet") {
                        Text("Read this out loud in a quiet spot. Earshot uses it to ignore you and only learn other people.")
                            .font(.system(size: 14)).foregroundStyle(ES.text2)
                        Text("“\(script)”")
                            .font(.system(size: 17, weight: .medium)).foregroundStyle(enrolling ? ES.text : ES.text2)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(ES.raised, in: .rect(cornerRadius: ES.control))
                        if enrolling {
                            ProgressView(value: progress).tint(ES.accent)
                        }
                        Button { Task { await enroll() } } label: {
                            Label(enrolling ? "Keep reading…" : (brain.wearerEnrolled ? "Re-record my voice" : "Record my voice"),
                                  systemImage: "mic.fill")
                        }
                        .buttonStyle(GlossyButtonStyle())
                        .disabled(enrolling)
                        if !enrollMsg.isEmpty { Text(enrollMsg).font(.system(size: 13)).foregroundStyle(ES.text2) }
                    }

                    card("Whispers", rig.route) {
                        slider("Volume", value: $ear.volume, range: 0.1...1)
                        slider("Speed", value: $ear.rate, range: 0.4...0.62)
                        Button {
                            brain.whisper("That's Maya Chen, product manager at Stripe. She's hiring interns.", interrupt: true)
                        } label: { Label("Test whisper", systemImage: "ear") }
                        .buttonStyle(PillButtonStyle())
                    }

                    card("Listening", nil) {
                        Toggle(isOn: $autoListen) {
                            Text("Start listening on launch").font(.system(size: 16)).foregroundStyle(ES.text)
                        }
                        .tint(ES.gradBottom)
                        VStack(alignment: .leading, spacing: 8) {
                            tip("airpods", "Press once: who is this?")
                            tip("airpods", "Press twice: ask a question")
                            tip("iphone", "Phone in a chest or jacket pocket, mic up")
                        }
                    }

                    card("Backend", brain.backendOK == true ? "Connected" : (brain.backendOK == nil ? nil : "Unreachable")) {
                        TextField("", text: $base, prompt: Text("http://your-mac.local:8100").foregroundStyle(ES.text3))
                            .font(.system(size: 15, design: .monospaced)).foregroundStyle(ES.text)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .onSubmit { save() }
                            .padding(.horizontal, 14).frame(height: 46)
                            .background(ES.raised, in: .rect(cornerRadius: ES.control))
                            .overlay(RoundedRectangle(cornerRadius: ES.control).strokeBorder(ES.hairline))
                        HStack(spacing: 10) {
                            Button("Save & test") { save() }
                            Button("Use my Mac") { base = API.defaultBase; save() }
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func card<C: View>(_ title: String, _ status: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 19, weight: .semibold)).tracking(-0.3).foregroundStyle(ES.text)
                Spacer()
                if let status { Text(status).font(.system(size: 12, weight: .medium)).foregroundStyle(ES.text3).lineLimit(1) }
            }
            content()
        }
        .padding(18)
        .contentCard(radius: ES.frame)
    }

    private func slider(_ label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(ES.text2)
            Slider(value: value, in: range).tint(ES.gradBottom)
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 14)).foregroundStyle(ES.text2)
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
