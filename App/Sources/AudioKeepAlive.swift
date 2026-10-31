import Foundation
import AVFoundation

/// Keeps the app alive in the background by looping a silent audio file.
/// Required because the proxy has no Network Extension privileges: without
/// this iOS suspends the process roughly 30 seconds after it leaves the screen.
final class AudioKeepAlive {
    private var player: AVAudioPlayer?
    private var active = false

    func start() {
        guard !active else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV())
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            self.player = player
            active = true
        } catch {
            // Without audio the proxy still works while the app is in the
            // foreground; it just cannot survive being backgrounded.
            active = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        active = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func silentWAV(seconds: Int = 1, sampleRate: Int = 8000) -> Data {
        let samples = sampleRate * seconds
        let dataSize = samples * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))
        data.append(le16(1))
        data.append(le32(sampleRate))
        data.append(le32(sampleRate * 2))
        data.append(le16(2))
        data.append(le16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(le32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }

    private static func le32(_ value: Int) -> Data {
        var v = UInt32(value).littleEndian
        return Data(bytes: &v, count: 4)
    }

    private static func le16(_ value: Int) -> Data {
        var v = UInt16(value).littleEndian
        return Data(bytes: &v, count: 2)
    }
}
