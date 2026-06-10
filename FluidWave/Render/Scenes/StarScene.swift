import Foundation
import Metal
import simd

/// A parallax starfield that twinkles with the spectrum, drifts while music
/// plays, and launches shooting stars on onsets.
final class StarScene: VisualScene {

    let name = "スターフィールド"

    private struct Uniforms {
        var time: Float
        var aspect: Float
        var level: Float
        var beat: Float
        var bass: Float
        var mid: Float
        var treble: Float
        var centroid: Float
        var drift: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
        var shooting0: SIMD4<Float>
        var shooting1: SIMD4<Float>
        var shooting2: SIMD4<Float>
        var shooting3: SIMD4<Float>
        var shootingBand: SIMD4<Float>
    }

    private let pipeline: MTLRenderPipelineState

    // CPU-side state.
    private var drift: Float = 0
    private var beatCooldown: Float = 0
    /// x, y = start (aspect-scaled space), z = age (>=1 inactive), w = angle.
    private var shootingStars = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 1, 0), count: 4)
    private var shootingBands = SIMD4<Float>(repeating: 0)

    init?(device: MTLDevice, library: MTLLibrary) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "starsVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "starsFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.pipeline = pipeline
    }

    func render(commandBuffer: MTLCommandBuffer, target: MTLTexture,
                features: AudioAnalyzer.Features, dt: Float, time: Float) {
        let aspect = Float(target.width) / Float(target.height)

        // The sky travels only while music plays.
        drift += dt * (0.01 + features.level * 0.18)
        if beatCooldown > 0 { beatCooldown -= dt }

        // Advance shooting stars.
        for i in 0..<shootingStars.count where shootingStars[i].z < 1 {
            shootingStars[i].z = min(shootingStars[i].z + dt * 1.1, 1)
        }

        // Launch a shooting star on strong onsets (rate-limited so they
        // stay special), tinted by the dominant register.
        if features.beat > 0.3 && beatCooldown <= 0 {
            if let slot = shootingStars.firstIndex(where: { $0.z >= 1 }) {
                beatCooldown = 0.9
                let goingLeft = Bool.random()
                let angle: Float = goingLeft
                    ? .pi + Float.random(in: 0.35...0.7)
                    : -Float.random(in: 0.35...0.7)
                let start = SIMD2<Float>(
                    Float.random(in: 0.25...(aspect - 0.25)),
                    Float.random(in: 0.55...0.92))
                shootingStars[slot] = SIMD4<Float>(start.x, start.y, 0.001, angle)

                let band: Float
                if features.bass >= features.mid && features.bass >= features.treble {
                    band = 0
                } else if features.mid >= features.treble {
                    band = 1
                } else {
                    band = 2
                }
                shootingBands[slot] = band
            }
        }

        var uniforms = Uniforms(
            time: time,
            aspect: aspect,
            level: features.level,
            beat: features.beat,
            bass: features.bass,
            mid: features.mid,
            treble: features.treble,
            centroid: features.centroid,
            drift: drift,
            shooting0: shootingStars[0],
            shooting1: shootingStars[1],
            shooting2: shootingStars[2],
            shooting3: shootingStars[3],
            shootingBand: shootingBands)

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
