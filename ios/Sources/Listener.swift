import AVFoundation
import Foundation
import Speech

/// Turn timing. A turn ends when the room goes quiet, not on a timer.
enum Turns {
    /// Trailing quiet that closes a turn. Short, so back-and-forth between two
    /// people splits into separate turns that can each be fingerprinted.
    static let trailingSilence: Double = 0.8
    /// Shorter than this is a cough, not a turn.
    static let minimum: Double = 0.6
    /// Long monologues are cut here so whispers aren't held up.
    static let ceiling: Double = 15
    /// RMS floor for "someone is talking" (float samples).
    static let gateFloor: Float = 0.008
    /// The gate sits this far above the measured room noise.
    static let gateMultiple: Float = 2.5
}

/// Thread-safe state shared with the realtime audio tap.
private final class TapState: @unchecked Sendable {
    let lock = NSLock()
    var request: SFSpeechAudioBufferRecognitionRequest?
    var samples: [Int16] = []
    var lastVoice: Double = 0
    var firstVoice: Double = 0
    var noise: Float = 0.01
    var level: Float = 0
    var converter: AVAudioConverter?
    var sourceFormat: AVAudioFormat?
    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func take() -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        let s = samples
        samples.removeAll(keepingCapacity: true)
        firstVoice = 0
        return s
    }
}

/// Always-on listening: AVAudioEngine tap → on-device speech recognition +
/// 16 kHz PCM for the voice fingerprint. Emits one `Turn` per stretch of speech.
@MainActor
final class Listener: ObservableObject {
    struct Turn {
        let text: String
        let wav: Data?
        let seconds: Double
    }

    @Published private(set) var running = false
    @Published private(set) var partial = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var problem: String?

    var onTurn: ((Turn) -> Void)?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var task: SFSpeechRecognitionTask?
    private let tap = TapState()
    private var ticker: Timer?
    private var tapInstalled = false
    /// While set, turns are not emitted (voice enrolment is recording).
    private var holdTurns = false
    private var taskStarted = Date()
    /// Set when on-device recognition errors out (no model, simulator); from
    /// then on recognition goes through Apple's servers.
    private var onDeviceBroken = false
    /// Keeps the app the "now playing" app so AirPods presses reach us.
    private let silence = AVAudioPlayerNode()

    static func requestPermissions() async -> String? {
        let mic = await AVAudioApplication.requestRecordPermission()
        if !mic { return "Microphone access is off. Settings › Earshot." }
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        if speech != .authorized { return "Speech recognition is off. Settings › Earshot." }
        return nil
    }

    func start() async {
        if running { return }
        if let p = await Self.requestPermissions() { problem = p; return }
        AudioRig.shared.activate()
        do {
            try buildGraph()
            try engine.start()
        } catch {
            problem = "Couldn't start the mic: \(error.localizedDescription)"
            return
        }
        silence.play()
        newRecognitionTask()
        running = true
        problem = nil
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        ticker?.invalidate(); ticker = nil
        task?.cancel(); task = nil
        tap.lock.lock(); tap.request = nil; tap.lock.unlock()
        silence.stop()
        engine.stop()
        running = false
        partial = ""
    }

    /// Rebuild after a route change (AirPods in/out invalidate the input format).
    func restartIfRunning() async {
        guard running else { return }
        stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        await start()
    }

    /// Record `seconds` of raw audio for voice enrolment.
    func record(seconds: Double) async -> Data? {
        let wasRunning = running
        if !running { await start() }
        guard running else { return nil }
        holdTurns = true
        _ = tap.take()
        tap.lock.lock(); tap.firstVoice = 1; tap.lock.unlock()  // keep samples flowing
        try? await Task.sleep(for: .seconds(seconds))
        let pcm = tap.take()
        holdTurns = false
        partial = ""
        newRecognitionTask()
        if !wasRunning { stop() }
        return pcm.isEmpty ? nil : Self.wav(pcm)
    }

    // MARK: - engine

    private func buildGraph() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw NSError(domain: "earshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input"]) }
        if !engine.attachedNodes.contains(silence) {
            engine.attach(silence)
            engine.connect(silence, to: engine.mainMixerNode, format: nil)
            if let f = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
               let buf = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 44_100) {
                buf.frameLength = 44_100  // zeros
                silence.scheduleBuffer(buf, at: nil, options: .loops)
            }
        }
        if tapInstalled { input.removeTap(onBus: 0) }
        let state = tap
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, when in
            Self.process(buffer, state: state)
        }
        tapInstalled = true
        engine.prepare()
    }

    /// Runs on the realtime audio thread.
    nonisolated private static func process(_ buffer: AVAudioPCMBuffer, state: TapState) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
        let now = CFAbsoluteTimeGetCurrent()

        state.lock.lock()
        state.request?.append(buffer)
        let gate = max(Turns.gateFloor, state.noise * Turns.gateMultiple)
        let voiced = rms > gate
        if voiced {
            state.lastVoice = now
            if state.firstVoice == 0 { state.firstVoice = now }
        } else {
            state.noise = state.noise * 0.98 + rms * 0.02
        }
        state.level = rms
        let capturing = state.firstVoice != 0
        if state.converter == nil || state.sourceFormat != buffer.format {
            state.sourceFormat = buffer.format
            state.converter = AVAudioConverter(from: buffer.format, to: state.target)
        }
        let converter = state.converter
        state.lock.unlock()

        // Keep a little pre-roll even before the gate opens, so the first
        // syllable isn't lost; the backend trims silence itself.
        guard let converter else { return }
        let ratio = 16_000 / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: state.target, frameCapacity: AVAudioFrameCount(Double(n) * ratio) + 16) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let p = out.int16ChannelData, out.frameLength > 0 else { return }
        let chunk = UnsafeBufferPointer(start: p[0], count: Int(out.frameLength))
        state.lock.lock()
        state.samples.append(contentsOf: chunk)
        let cap = capturing ? 16_000 * 20 : 16_000 / 2  // 20 s turn / 0.5 s pre-roll
        if state.samples.count > cap { state.samples.removeFirst(state.samples.count - cap) }
        state.lock.unlock()
    }

    private func newRecognitionTask() {
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        let onDevice = !onDeviceBroken && recognizer?.supportsOnDeviceRecognition == true
        req.requiresOnDeviceRecognition = onDevice
        tap.lock.lock(); tap.request = req; tap.lock.unlock()
        taskStarted = Date()
        var heard = false
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            if let text = result?.bestTranscription.formattedString {
                heard = true
                Task { @MainActor in
                    guard let self, self.tap.request === req else { return }
                    self.partial = text
                }
            } else if error != nil, onDevice, !heard {
                Task { @MainActor in
                    guard let self, self.tap.request === req else { return }
                    self.onDeviceBroken = true
                    self.newRecognitionTask()
                }
            }
        }
    }

    private func tick() {
        tap.lock.lock()
        let first = tap.firstVoice, last = tap.lastVoice, lvl = tap.level
        tap.lock.unlock()
        level = lvl
        guard !holdTurns else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if first == 0 {
            // Recognition tasks die after ~1 min; roll quiet ones over.
            if Date().timeIntervalSince(taskStarted) > 50 { partial = ""; newRecognitionTask() }
            return
        }
        let length = now - first
        let quiet = now - last
        guard (quiet >= Turns.trailingSilence && length >= Turns.minimum) || length >= Turns.ceiling else { return }
        let text = partial
        let pcm = tap.take()
        partial = ""
        tap.request?.endAudio()
        newRecognitionTask()
        let seconds = Double(pcm.count) / 16_000
        if text.isEmpty && seconds < 1.5 { return }  // a noise, not speech
        onTurn?(Turn(text: text, wav: Self.wav(pcm), seconds: seconds))
    }

    /// 16 kHz mono 16-bit WAV.
    static func wav(_ pcm: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let size = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + size)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(size)
        pcm.withUnsafeBufferPointer { d.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        return d
    }
}
