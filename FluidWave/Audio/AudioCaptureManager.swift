import Foundation
import ScreenCaptureKit
import CoreMedia
import AVFAudio

/// Captures the Mac's *system* audio (e.g. whatever the Music app is playing)
/// using ScreenCaptureKit — no virtual audio device (BlackHole etc.) required.
///
/// Requires macOS 13.0+ and the Screen Recording permission, which the system
/// prompts for automatically the first time the stream starts.
@available(macOS 13.0, *)
final class AudioCaptureManager: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {

    enum State: Equatable {
        case idle
        case starting
        case capturing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let analyzer: AudioAnalyzer
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.fluidwave.audio.sampleQueue")

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        guard state == .idle || isFailed else { return }
        setState(.starting)

        Task {
            do {
                // We must hand SCStream at least one display, even though we
                // only care about audio. Pick the primary display.
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    throw CaptureError.noDisplay
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                // Keep the (unused) video stream tiny and slow to save power.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                analyzer.sampleRate = Double(config.sampleRate)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()

                self.stream = stream
                await MainActor.run { self.setState(.capturing) }
            } catch {
                await MainActor.run { self.setState(.failed(self.describe(error))) }
            }
        }
    }

    func stop() {
        guard let stream else { setState(.idle); return }
        Task {
            try? await stream.stopCapture()
            self.stream = nil
            await MainActor.run { self.setState(.idle) }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let firstBuffer = audioBufferList.first,
                      let data = firstBuffer.mData else { return }

                let channels = max(1, Int(firstBuffer.mNumberChannels))
                let totalFloats = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let frameCount = totalFloats / channels
                guard frameCount > 0 else { return }

                let pointer = data.assumingMemoryBound(to: Float.self)
                var mono = [Float](repeating: 0, count: frameCount)
                // For interleaved audio, take channel 0; for non-interleaved the
                // first buffer is already a single channel (channels == 1).
                for frame in 0..<frameCount {
                    mono[frame] = pointer[frame * channels]
                }
                analyzer.append(samples: mono)
            }
        } catch {
            // A single dropped buffer is not fatal; keep the stream alive.
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.setState(.failed(self.describe(error))) }
    }

    // MARK: Helpers

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func setState(_ newState: State) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { self.state = newState }
        }
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == SCStreamError.errorDomain {
            return "画面収録の許可が必要です。システム設定 > プライバシーとセキュリティ > 画面収録 で FluidWave を有効にしてください。(\(ns.code))"
        }
        return error.localizedDescription
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "利用可能なディスプレイが見つかりませんでした。"
            }
        }
    }
}
