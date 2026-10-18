import Foundation
import MediaPlayer
import Speech
import UIKit

/// Ties it together: every turn the listener hears goes to the backend, and
/// whatever whisper comes back goes to the AirPods.
///
/// AirPods controls (while Earshot is the now-playing app):
///   press once  → "who is this?" — re-whisper the person you're talking to
///   press twice → ask a question; the next thing you say is the question
@MainActor
final class Brain: ObservableObject {
    static let shared = Brain()

    struct Line: Identifiable {
        let id = UUID()
        let at = Date()
        var who: String       // "You", "Maya Chen", "voice 2"
        var kind: String      // me | person | unknown
        let text: String
        let match: Double
    }

    struct Whisper: Identifiable {
        let id = UUID()
        let at = Date()
        let text: String
        let spoken: Bool
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var whispers: [Whisper] = []
    @Published private(set) var talkingTo: Person?
    @Published private(set) var talkingToUnknown: String?
    @Published private(set) var session: String?
    @Published private(set) var backendOK: Bool?
    @Published private(set) var wearerEnrolled = false
    @Published private(set) var lastError: String?
    @Published private(set) var awaitingQuestion = false
    @Published private(set) var pending = 0

    let listener = Listener()

    private init() {
        listener.onTurn = { [weak self] t in self?.handle(t) }
        setupRemoteCommands()
    }

    func boot() async {
        AudioRig.shared.activate()
        await checkBackend()
        if ProcessInfo.processInfo.arguments.contains("-rehearse") {
            await rehearse()
            return
        }
        if UserDefaults.standard.object(forKey: "autoListen") as? Bool ?? true {
            await listener.start()
        }
    }

    func checkBackend() async {
        do {
            let h = try await API.health()
            backendOK = h.ok
            wearerEnrolled = h.wearer_enrolled
            lastError = nil
        } catch {
            backendOK = false
            lastError = "Backend unreachable at \(API.base)"
        }
    }

    func toggleListening() async {
        if listener.running { listener.stop() } else { await listener.start() }
    }

    // MARK: turns

    private func handle(_ t: Listener.Turn) {
        if awaitingQuestion, !t.text.isEmpty {
            awaitingQuestion = false
            Task { await ask(t.text) }
            return
        }
        pending += 1
        Task {
            defer { pending -= 1 }
            do {
                let r = try await API.turn(session: session, text: t.text, wav: t.wav)
                session = r.session
                backendOK = true
                lastError = nil
                let who: String
                switch r.speaker {
                case "me": who = "You"
                case "person": who = r.person?.name ?? "?"
                default: who = r.cluster ?? "Someone"
                }
                // The server transcribes when the phone's recogniser came back empty.
                let said = t.text.isEmpty ? (r.text ?? "") : t.text
                if !said.isEmpty || r.speaker != "unknown" {
                    lines.append(Line(who: who, kind: r.speaker, text: said.isEmpty ? "…" : said, match: r.sim))
                    if lines.count > 80 { lines.removeFirst(lines.count - 80) }
                }
                if let c = r.named_cluster, let p = r.person {
                    // Earlier lines from this voice now have a name.
                    for i in lines.indices where lines[i].kind == "unknown" && lines[i].who == c {
                        lines[i].who = p.name; lines[i].kind = "person"
                    }
                }
                if r.speaker == "person", let p = r.person {
                    talkingTo = p; talkingToUnknown = nil
                } else if r.speaker == "unknown", let c = r.cluster {
                    talkingTo = nil; talkingToUnknown = c
                } else if r.speaker == "me", let p = r.person, r.event == "named_by_you" {
                    talkingTo = p; talkingToUnknown = nil
                }
                whisper(r.whisper)
            } catch {
                backendOK = false
                lastError = error.localizedDescription
            }
        }
    }

    func whisper(_ text: String, interrupt: Bool = false) {
        guard !text.isEmpty else { return }
        let spoken = Whisperer.shared.say(text, interrupt: interrupt)
        whispers.insert(Whisper(text: text, spoken: spoken), at: 0)
        if whispers.count > 30 { whispers.removeLast() }
    }

    // MARK: controls

    func whoIsThis() async {
        guard let session else { whisper("I haven't heard anyone yet.", interrupt: true); return }
        do { whisper(try await API.whois(session: session), interrupt: true) }
        catch { whisper("Can't reach the backend.", interrupt: true) }
    }

    func startQuestion() {
        awaitingQuestion = true
        whisper("Ask me.", interrupt: true)
    }

    func ask(_ q: String) async {
        do { whisper(try await API.ask(q, session: session), interrupt: true) }
        catch { whisper("Can't reach the backend.", interrupt: true) }
    }

    func endSession() async {
        guard let s = session else { return }
        do { whisper(try await API.endSession(s), interrupt: true) } catch {}
        session = nil
        talkingTo = nil
        talkingToUnknown = nil
        lines.removeAll()
    }

    func enroll(seconds: Double, reset: Bool) async -> String {
        guard let wav = await listener.record(seconds: seconds) else { return "Couldn't record." }
        do {
            let n = try await API.enrollMe(wav: wav, reset: reset)
            wearerEnrolled = true
            return "Saved your voice (\(n) sample\(n == 1 ? "" : "s"))."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: rehearsal

    /// Plays Documents/script.txt through the real pipeline without the live
    /// mic: each line is a WAV name in Documents, transcribed on-device and
    /// sent as a turn. "enroll:<name>" records it as the wearer's voice.
    /// Launch with `-rehearse`. Used to test in the simulator, whose mic input
    /// deadlocks Core Audio.
    func rehearse() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let script = try? String(contentsOf: docs.appending(path: "script.txt"), encoding: .utf8) else {
            lastError = "rehearse: no script.txt"; return
        }
        _ = await Listener.requestPermissions()
        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "whois" { await whoIsThis(); try? await Task.sleep(for: .seconds(3)); continue }
            if line.hasPrefix("ask:") { await ask(String(line.dropFirst(4))); try? await Task.sleep(for: .seconds(3)); continue }
            let enroll = line.hasPrefix("enroll:")
            let name = enroll ? String(line.dropFirst(7)) : line
            let url = docs.appending(path: "\(name).wav")
            guard let wav = try? Data(contentsOf: url) else { lastError = "rehearse: missing \(name)"; continue }
            if enroll {
                _ = try? await API.enrollMe(wav: wav, reset: true)
                wearerEnrolled = true
                continue
            }
            var text = await Self.transcribe(url)
            if text.isEmpty {  // simulator: no speech service; use a sidecar transcript
                text = (try? String(contentsOf: docs.appending(path: "\(name).txt"), encoding: .utf8)) ?? ""
            }
            print("[earshot] rehearse \(name): \(text)")
            handle(Listener.Turn(text: text, wav: wav, seconds: Double(wav.count - 44) / 32_000))
            while pending > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            print("[earshot] whisper: \(whispers.first?.text ?? "")")
            try? await Task.sleep(for: .seconds(1))
        }
        print("[earshot] rehearse done")
    }

    static func transcribe(_ url: URL, onDevice: Bool = true) async -> String {
        let text = await transcribeOnce(url, onDevice: onDevice)
        if text.isEmpty && onDevice { return await transcribeOnce(url, onDevice: false) }
        return text
    }

    private static func transcribeOnce(_ url: URL, onDevice: Bool) async -> String {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { return "" }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.addsPunctuation = true
        if onDevice && r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return await withCheckedContinuation { c in
            var done = false
            r.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal { done = true; c.resume(returning: result.bestTranscription.formattedString) }
                else if error != nil { done = true; c.resume(returning: "") }
            }
        }
    }

    private func setupRemoteCommands() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let c = MPRemoteCommandCenter.shared()
        let who: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            Task { @MainActor in await self?.whoIsThis() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget(handler: who)
        c.playCommand.addTarget(handler: who)
        c.pauseCommand.addTarget(handler: who)
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.startQuestion() }
            return .success
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Earshot is listening",
            MPMediaItemPropertyArtist: "Press: who is this · Double press: ask",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }
}
