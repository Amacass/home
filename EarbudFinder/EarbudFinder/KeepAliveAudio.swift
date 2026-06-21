import Foundation
import AVFAudio

/// バックグラウンドでもルート変更通知を受け取り続けるための「無音再生」キープアライブ。
///
/// 他アプリ（音楽アプリ）で再生中にイヤホンが切れた瞬間を、自アプリがサスペンドされていても
/// 捕まえるには、自アプリのオーディオセッションをアクティブに保つ必要がある。
/// そこで音量ゼロ相当の無音WAVをループ再生する（`.mixWithOthers` で他の音は邪魔しない）。
///
/// 注意: バックグラウンドオーディオは Background Modes(Audio) の有効化が必要。
/// 常時オンはバッテリーを消費するため、設定でON/OFFできる前提の実装にしている。
final class KeepAliveAudio {
    private var player: AVAudioPlayer?

    var isRunning: Bool { player?.isPlaying ?? false }

    func start() {
        guard player == nil else {
            player?.play()
            return
        }
        do {
            let data = Self.makeSilentWAV(seconds: 2)
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1   // 無限ループ
            player.volume = 0
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            // 再生に失敗してもアプリ自体は動く（フォアグラウンド検知のみになる）。
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }

    // MARK: - 無音WAV生成

    /// 指定秒数の無音モノラルPCM WAVを生成する。
    private static func makeSilentWAV(seconds: Double, sampleRate: Int = 44_100) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let numSamples = Int(Double(sampleRate) * seconds)
        let dataSize = numSamples * bytesPerSample * channels

        var data = Data()
        func appendString(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendUInt32LE(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt16LE(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        // RIFFチャンク
        appendString("RIFF")
        appendUInt32LE(UInt32(36 + dataSize))
        appendString("WAVE")
        // fmtサブチャンク
        appendString("fmt ")
        appendUInt32LE(16)                                              // サブチャンクサイズ
        appendUInt16LE(1)                                              // PCM
        appendUInt16LE(UInt16(channels))
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(sampleRate * channels * bytesPerSample))  // バイトレート
        appendUInt16LE(UInt16(channels * bytesPerSample))              // ブロックアライン
        appendUInt16LE(UInt16(bitsPerSample))
        // dataサブチャンク（すべて0＝無音）
        appendString("data")
        appendUInt32LE(UInt32(dataSize))
        data.append(Data(count: dataSize))

        return data
    }
}
