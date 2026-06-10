import Foundation
import Metal
import simd

/// Concentric neon rings that breathe with each register and tick with the
/// estimated BPM — a calm, mandala-like counterpart to the fluid scene.
final class RingsScene: VisualScene {

    let name = "スペクトラム・リング"

    private struct Uniforms {
        var time: Float
        var aspect: Float
        var level: Float
        var beatPulse: Float
        var bass: Float
        var mid: Float
        var treble: Float
        var ripple: Float
        var bpmPhase: Float
        var centroid: Float
        var pad: SIMD2<Float> = .zero
    }

    private let pipeline: MTLRenderPipelineState

    // CPU-side envelopes.
    private var beatPulse: Float = 0
    private var ripple: Float = 1 // >= 1 means inactive
    private var bpmPhase: Float = 0.99

    init?(device: MTLDevice, library: MTLLibrary) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "ringsVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "ringsFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipeline = pipeline
    }

    func render(commandBuffer: MTLCommandBuffer, target: MTLTexture,
                features: AudioAnalyzer.Features, dt: Float, time: Float) {
        // Advance the beat phase from the tempo estimate; onset resets it so
        // the rings visibly "tick" in time with the music.
        if features.bpm > 0 {
            bpmPhase += dt * features.bpm / 60.0
            bpmPhase -= floor(bpmPhase)
        } else {
            bpmPhase = 0.99 // unknown tempo -> no tick
        }

        if features.beat > 0 {
            beatPulse = max(beatPulse, 0.5 + features.beat)
            ripple = 0.001
            bpmPhase = 0
        }
        beatPulse *= exp(-dt * 3.0)
        if ripple < 1 { ripple = min(ripple + dt * 1.4, 1) }

        var uniforms = Uniforms(
            time: time,
            aspect: Float(target.width) / Float(target.height),
            level: features.level,
            beatPulse: beatPulse,
            bass: features.bass,
            mid: features.mid,
            treble: features.treble,
            ripple: ripple,
            bpmPhase: bpmPhase,
            centroid: features.centroid)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
