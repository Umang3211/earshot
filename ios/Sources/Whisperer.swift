import AVFoundation
import UIKit

/// Speaks into the AirPods, quietly. Refuses to speak out loud: if the output
/// isn't headphones, the whisper is shown on screen with a tap on the wrist
/// instead, so nobody across the table hears "That's Maya, she's hiring".
@MainActor
final class Whisperer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Whisperer()

    @Published private(set) var speaking = false
    @Published var volume: Float = UserDefaults.standard.object(forKey: "whisperVolume") as? Float ?? 0.6 {
        didSet { UserDefaults.standard.set(volume, forKey: "whisperVolume") }
    }
    @Published var rate: Float = UserDefaults.standard.object(forKey: "whisperRate") as? Float ?? 0.54 {
        didSet { UserDefaults.standard.set(rate, forKey: "whisperRate") }
    }

    private let synth = AVSpeechSynthesizer()
    private lazy var voice: AVSpeechSynthesisVoice? = {
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en-US") }
        return en.first { $0.quality == .premium } ?? en.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    /// Returns false when it couldn't be spoken privately.
    @discardableResult
    func say(_ text: String, interrupt: Bool = false) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        guard AudioRig.isPrivate(AVAudioSession.sharedInstance().currentRoute) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return false
        }
        if interrupt { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: t)
        u.voice = voice
        u.volume = volume
        u.rate = rate
        u.preUtteranceDelay = 0.05
        synth.speak(u)
        return true
    }

    func hush() { synth.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = true }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = s.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}
