import AVFoundation
import Foundation

/// The one audio session. Capture is pinned to the iPhone's own microphone and
/// whispers go out to AirPods over A2DP.
///
/// Why the phone mic and not the AirPods mic: AirPods beamform toward the
/// wearer and suppress everyone else, which is exactly backwards for hearing
/// the person in front of you. Leaving out `.allowBluetooth` (HFP) also keeps
/// AirPods in high-quality A2DP output instead of dropping to call audio.
@MainActor
final class AudioRig: ObservableObject {
    static let shared = AudioRig()

    @Published private(set) var route = "—"
    @Published private(set) var privateOutput = false
    @Published private(set) var error: String?
    /// Bumped on every route change; the listener rebuilds its tap on it.
    @Published private(set) var generation = 0

    private var configured = false

    func activate() {
        let s = AVAudioSession.sharedInstance()
        do {
            if !configured {
                try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
                observe()
                configured = true
            }
            try s.setActive(true)
            pinPhoneMic()
            error = nil
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
        }
        refresh()
    }

    func pinPhoneMic() {
        let s = AVAudioSession.sharedInstance()
        if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? s.setPreferredInput(mic)
        }
    }

    /// Output is something only the wearer can hear.
    static func isPrivate(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones].contains($0.portType)
        }
    }

    private func refresh() {
        let r = AVAudioSession.sharedInstance().currentRoute
        privateOutput = Self.isPrivate(r)
        let out = r.outputs.first?.portName ?? "—"
        let mic = r.inputs.first?.portName ?? "—"
        route = "mic: \(mic) · ear: \(out)"
    }

    private func observe() {
        let c = NotificationCenter.default
        c.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pinPhoneMic()
                self.refresh()
                self.generation += 1
            }
        }
        c.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self.activate()
                self.generation += 1
            }
        }
        c.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.configured = false
                self.activate()
                self.generation += 1
            }
        }
    }
}
