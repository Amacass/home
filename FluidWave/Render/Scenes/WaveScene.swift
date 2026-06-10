import Foundation
import Metal
import simd

/// Three neon oscilloscope traces of the live waveform — bass (smoothed)
/// low on screen, mids center, raw treble detail on top.
final class WaveScene: VisualScene {

    let name = "ウェーブ・ライン"

    private struct Uniforms {
        var time: Float
        var aspect: Float
        var level: Float
        var beat: Float
        var bass: Float
        var mid: Float
        var treble: Float
        var beatPulse: Float
    }

    private let pipeline: MTLRenderPipelineState
    private let linesBuffer: MTLBuffer
    private let waveLength = AudioAnalyzer.waveformLength

    private var beatPulse: Float = 0

    init?(device: MTLDevice, library: MTLLibrary) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "waveVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "waveFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let buffer = device.makeBuffer(
                length: MemoryLayout<Float>.stride * AudioAnalyzer.waveformLength * 3,
                options: .storageModeShared) else {
            return nil
        }
        self.pipeline = pipeline
        self.linesBuffer = buffer
    }

    func render(commandBuffer: MTLCommandBuffer, target: MTLTexture,
                features: AudioAnalyzer.Features, dt: Float, time: Float) {
        if features.beat > 0 { beatPulse = max(beatPulse, features.beat) }
        beatPulse *= exp(-dt * 5.0)

        updateLines(from: features.waveform)

        var uniforms = Uniforms(
            time: time,
            aspect: Float(target.width) / Float(target.height),
            level: features.level,
            beat: features.beat,
            bass: features.bass,
            mid: features.mid,
            treble: features.treble,
            beatPulse: beatPulse)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(linesBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Build the three traces: heavily smoothed (bass), lightly smoothed
    /// (mid), and raw (treble), packed sequentially into the shared buffer.
    private func updateLines(from waveform: [Float]) {
        let n = waveLength
        var raw = waveform.count == n ? waveform : [Float](repeating: 0, count: n)
        // Clamp stray spikes so a single sample can't throw a trace offscreen.
        for i in 0..<n { raw[i] = max(-1, min(1, raw[i])) }

        let bassLine = boxSmooth(raw, radius: 8)
        let midLine = boxSmooth(raw, radius: 2)

        let pointer = linesBuffer.contents().assumingMemoryBound(to: Float.self)
        for i in 0..<n {
            pointer[i] = bassLine[i] * 1.4
            pointer[n + i] = midLine[i]
            pointer[2 * n + i] = raw[i]
        }
    }

    private func boxSmooth(_ x: [Float], radius: Int) -> [Float] {
        let n = x.count
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            var count: Float = 0
            for j in max(0, i - radius)...min(n - 1, i + radius) {
                sum += x[j]
                count += 1
            }
            out[i] = sum / count
        }
        return out
    }
}
