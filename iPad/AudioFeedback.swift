import AVFoundation
import Combine
import UIKit

/// Short speaker cues, not physical haptics. All audio work stays off the input queue.
final class AudioFeedback: ObservableObject {
    static let shared = AudioFeedback()
    enum Cue: CaseIterable { case pencil, click, tool }

    @Published var enabled = UserDefaults.standard.object(forKey: "audioFeedback") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "audioFeedback")
            if !enabled { queue.async { self.stopPlayers() } }
        }
    }
    @Published var volume = UserDefaults.standard.object(forKey: "feedbackVolume") as? Double ?? 0.45 {
        didSet { UserDefaults.standard.set(volume, forKey: "feedbackVolume") }
    }
    private let queue = DispatchQueue(label: "dev.morgan.pencilbridge.audio", qos: .userInteractive)
    // The following state belongs exclusively to queue.
    private var players: [Cue: [AVAudioPlayer]] = [:]
    private var active = false
    private var interrupted = false
    private var lastSound = -Double.infinity
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let began = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.interrupted = began
                if began { self.stopPlayers() }
                else if self.active { self.prepare() }
            }
        }
    }

    func setActive(_ active: Bool) {
        queue.async {
            self.active = active
            if active { self.prepare() }
            else {
                self.stopPlayers()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// Called after sending input. No synthesis, decoding or session setup on the caller's thread.
    func play(_ cue: Cue) {
        guard enabled, volume.isFinite else { return }
        let level = Float(min(1, max(0, volume)))
        guard level > 0 else { return }
        queue.async {
            guard self.active, !self.interrupted else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastSound >= 0.04,
                  let player = self.players[cue]?.first(where: { !$0.isPlaying }) else { return }
            player.currentTime = 0
            player.volume = level
            if player.play() { self.lastSound = now }
        }
    }

    private func prepare() {
        guard !interrupted else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            if players.isEmpty {
                for cue in Cue.allCases {
                    let data = Self.wave(cue)
                    players[cue] = try (0..<2).map { _ in try AVAudioPlayer(data: data) }
                }
            }
            players.values.flatMap { $0 }.forEach { _ = $0.prepareToPlay() }
        } catch {
            // Audio is optional. Input continues normally if the route/session is unavailable.
            players.removeAll()
        }
    }

    private func stopPlayers() {
        players.values.flatMap { $0 }.forEach { $0.stop() }
        lastSound = -Double.infinity
    }

    /// Original 22 ms, mono PCM cues with smooth attack/release and a restrained peak.
    private static func wave(_ cue: Cue) -> Data {
        let rate = 44_100
        let count = Int(Double(rate) * 0.022)
        let frequency: Double
        switch cue {
        case .pencil: frequency = 220
        case .click: frequency = 420
        case .tool: frequency = 620
        }
        var data = Data()
        func word(_ value: UInt16) {
            data.append(UInt8(value & 255)); data.append(UInt8(value >> 8))
        }
        func dword(_ value: UInt32) {
            word(UInt16(value & 65535)); word(UInt16(value >> 16))
        }
        data.append(contentsOf: "RIFF".utf8); dword(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); dword(16)
        word(1); word(1); dword(UInt32(rate)); dword(UInt32(rate * 2)); word(2); word(16)
        data.append(contentsOf: "data".utf8); dword(UInt32(count * 2))
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            let attack = min(1, t / 0.0008)
            let release = min(1, Double(count - 1 - index) / (Double(rate) * 0.003))
            let envelope = attack * release * exp(-t * 240)
            let tone = sin(2 * .pi * frequency * t) * 0.7 + sin(2 * .pi * 1900 * t) * 0.3
            let sample = Int16((tone * envelope * 0.55 * 32767).rounded())
            word(UInt16(bitPattern: sample))
        }
        return data
    }
}
