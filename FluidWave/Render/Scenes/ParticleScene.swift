import Foundation
import Metal
import simd

/// Tens of thousands of glowing particles drifting in a curl-noise flow
/// field, with fading trails. Bass particles live low / mids center /
/// treble high (pitch-height correspondence), each glowing in its own
/// register paint so the neon look matches the fluid scene.
final class ParticleScene: VisualScene {

    let name = "パーティクル・フロー"

    private struct Uniforms {
        var dt: Float
        var time: Float
        var level: Float
        var beat: Float
        var bands: SIMD4<Float>
        var aspect: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    private struct Particle {
        var pos: SIMD2<Float>
        var vel: SIMD2<Float>
        var data: SIMD2<Float> // x = band (0/1/2), y = seed
    }

    private let particleCount = 60_000

    private let device: MTLDevice
    private let updatePipeline: MTLComputePipelineState
    private let fadePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let particleBuffer: MTLBuffer
    private let accum: PingPongTexture
    private let accumWidth: Int
    private let accumHeight: Int

    init?(device: MTLDevice, library: MTLLibrary, width: Int, height: Int) {
        self.device = device
        self.accumWidth = width
        self.accumHeight = height

        guard let updateFn = library.makeFunction(name: "particleUpdate"),
              let fadeFn = library.makeFunction(name: "fadeAccum"),
              let update = try? device.makeComputePipelineState(function: updateFn),
              let fade = try? device.makeComputePipelineState(function: fadeFn) else {
            return nil
        }
        self.updatePipeline = update
        self.fadePipeline = fade

        // Additive point rendering into the accumulation texture.
        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction = library.makeFunction(name: "particleVertexFn")
        renderDescriptor.fragmentFunction = library.makeFunction(name: "particleFragmentFn")
        let attachment = renderDescriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba16Float
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        guard let render = try? device.makeRenderPipelineState(descriptor: renderDescriptor) else {
            return nil
        }
        self.renderPipeline = render

        let presentDescriptor = MTLRenderPipelineDescriptor()
        presentDescriptor.vertexFunction = library.makeFunction(name: "particlePresentVertex")
        presentDescriptor.fragmentFunction = library.makeFunction(name: "particlePresentFragment")
        presentDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        guard let present = try? device.makeRenderPipelineState(descriptor: presentDescriptor) else {
            return nil
        }
        self.presentPipeline = present

        // Particle storage, randomly initialized; band assigned round-robin.
        var particles = [Particle]()
        particles.reserveCapacity(particleCount)
        for i in 0..<particleCount {
            particles.append(Particle(
                pos: SIMD2<Float>(.random(in: 0...1), .random(in: 0...1)),
                vel: .zero,
                data: SIMD2<Float>(Float(i % 3), .random(in: 0...1))))
        }
        guard let buffer = device.makeBuffer(
            bytes: particles,
            length: MemoryLayout<Particle>.stride * particleCount,
            options: .storageModeShared) else {
            return nil
        }
        self.particleBuffer = buffer

        func makeTexture() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let a0 = makeTexture(), let a1 = makeTexture() else { return nil }
        self.accum = PingPongTexture(a0, a1)
    }

    // MARK: VisualScene

    func render(commandBuffer: MTLCommandBuffer, target: MTLTexture,
                features: AudioAnalyzer.Features, dt: Float, time: Float) {
        var uniforms = Uniforms(
            dt: dt,
            time: time,
            level: features.level,
            beat: features.beat,
            bands: SIMD4<Float>(features.bass, features.mid, features.treble, 0),
            aspect: Float(accumWidth) / Float(accumHeight))

        // 1. Fade trails. Loud music keeps longer trails; silence clears fast.
        var decay = 0.90 + 0.06 * features.level
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(fadePipeline)
            encoder.setTexture(accum.src, index: 0)
            encoder.setTexture(accum.dst, index: 1)
            encoder.setBytes(&decay, length: MemoryLayout<Float>.stride, index: 0)
            let group = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: (accumWidth + 15) / 16,
                               height: (accumHeight + 15) / 16, depth: 1)
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
            encoder.endEncoding()
        }

        // 2. Advance particles.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(updatePipeline)
            encoder.setBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            let group = MTLSize(width: 256, height: 1, depth: 1)
            let grid = MTLSize(width: (particleCount + 255) / 256, height: 1, depth: 1)
            encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
            encoder.endEncoding()
        }

        // 3. Draw particles additively into the faded accumulation texture.
        let accumPass = MTLRenderPassDescriptor()
        accumPass.colorAttachments[0].texture = accum.dst
        accumPass.colorAttachments[0].loadAction = .load
        accumPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: accumPass) {
            encoder.setRenderPipelineState(renderPipeline)
            encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            encoder.endEncoding()
        }
        accum.swap()

        // 4. Composite trails to the scene target with the neon paint look.
        let presentPass = MTLRenderPassDescriptor()
        presentPass.colorAttachments[0].texture = target
        presentPass.colorAttachments[0].loadAction = .clear
        presentPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        presentPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: presentPass) {
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentTexture(accum.src, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }
}
