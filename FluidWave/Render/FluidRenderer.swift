import Foundation
import Metal
import MetalKit
import simd

/// GPU fluid solver (stable fluids / Stam) that is driven by audio features.
///
/// The solver keeps everything on the GPU using ping-pong textures. Each frame
/// it: applies audio-driven forces, advects velocity, projects the field to be
/// divergence-free, advects the dye, then renders the dye to the drawable.
final class FluidRenderer: NSObject, MTKViewDelegate {

    // MARK: Uniform layouts (mirror the structs in Fluid.metal)

    private struct SimpleUniforms {
        var texelSize: SIMD2<Float>
    }

    private struct AdvectUniforms {
        var texelSize: SIMD2<Float>
        var dt: Float
        var dissipation: Float
    }

    private struct SplatUniforms {
        var texelSize: SIMD2<Float>
        var point: SIMD2<Float>
        var radius: Float
        var aspect: Float
        var value: SIMD4<Float>
    }

    // MARK: Ping-pong texture pair

    private final class PingPong {
        var src: MTLTexture
        var dst: MTLTexture
        init(_ a: MTLTexture, _ b: MTLTexture) { src = a; dst = b }
        func swap() { Swift.swap(&src, &dst) }
    }

    // MARK: Configuration

    /// Simulation grid resolution (16:9). Lower this if you want more FPS.
    private let simWidth: Int
    private let simHeight: Int
    private let pressureIterations: Int

    // MARK: Metal objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private let advectPipeline: MTLComputePipelineState
    private let divergencePipeline: MTLComputePipelineState
    private let jacobiPipeline: MTLComputePipelineState
    private let gradientPipeline: MTLComputePipelineState
    private let splatPipeline: MTLComputePipelineState
    private let displayPipeline: MTLRenderPipelineState

    private let velocity: PingPong
    private let dye: PingPong
    private let pressure: PingPong
    private let divergenceTex: MTLTexture

    // MARK: Audio source

    private weak var analyzer: AudioAnalyzer?

    // MARK: Animation state

    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var phase: Float = 0
    private var beatCooldown: Float = 0

    // MARK: Init

    init?(mtkView: MTKView, analyzer: AudioAnalyzer) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.analyzer = analyzer

        // Local copies so texture allocation below never touches `self`
        // (which is illegal before `super.init()`).
        let width = 640
        let height = 360
        self.simWidth = width
        self.simHeight = height
        self.pressureIterations = 24

        func computePipeline(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }

        guard let advect = computePipeline("advect"),
              let divergence = computePipeline("divergence"),
              let jacobi = computePipeline("jacobi"),
              let gradient = computePipeline("subtractGradient"),
              let splat = computePipeline("splat") else {
            return nil
        }
        self.advectPipeline = advect
        self.divergencePipeline = divergence
        self.jacobiPipeline = jacobi
        self.gradientPipeline = gradient
        self.splatPipeline = splat

        // Display render pipeline.
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "displayFragment")
        descriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        guard let display = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.displayPipeline = display

        // Allocate textures. Uses only locals (`device`, `width`, `height`)
        // so it can run before `super.init()`.
        func makeTexture(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }

        guard let v0 = makeTexture(.rgba16Float), let v1 = makeTexture(.rgba16Float),
              let d0 = makeTexture(.rgba16Float), let d1 = makeTexture(.rgba16Float),
              let p0 = makeTexture(.r16Float), let p1 = makeTexture(.r16Float),
              let div = makeTexture(.r16Float) else {
            return nil
        }
        self.velocity = PingPong(v0, v1)
        self.dye = PingPong(d0, d1)
        self.pressure = PingPong(p0, p1)
        self.divergenceTex = div

        super.init()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var dt = Float(now - lastTime)
        lastTime = now
        // Clamp dt so a stalled frame doesn't blow up the simulation.
        dt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0)

        let features = analyzer?.currentFeatures() ?? AudioAnalyzer.Features()

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        applyAudioForces(commandBuffer, features: features, dt: dt)
        step(commandBuffer, dt: dt)

        if let drawable = view.currentDrawable,
           let passDescriptor = view.currentRenderPassDescriptor {
            renderDye(commandBuffer, passDescriptor: passDescriptor)
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    // MARK: Simulation step

    private func step(_ commandBuffer: MTLCommandBuffer, dt: Float) {
        let texel = SIMD2<Float>(1.0 / Float(simWidth), 1.0 / Float(simHeight))

        // Advect velocity by itself.
        runAdvect(commandBuffer, source: velocity, velocity: velocity.src,
                  texel: texel, dt: dt, dissipation: 0.999)

        // Projection: divergence -> pressure solve -> subtract gradient.
        computeDivergence(commandBuffer, texel: texel)
        solvePressure(commandBuffer, texel: texel)
        subtractGradient(commandBuffer, texel: texel)

        // Advect dye by the (now divergence-free) velocity field.
        runAdvect(commandBuffer, source: dye, velocity: velocity.src,
                  texel: texel, dt: dt, dissipation: 0.994)
    }

    private func runAdvect(_ commandBuffer: MTLCommandBuffer, source: PingPong,
                           velocity velocityTex: MTLTexture, texel: SIMD2<Float>,
                           dt: Float, dissipation: Float) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(advectPipeline)
        encoder.setTexture(source.src, index: 0)
        encoder.setTexture(velocityTex, index: 1)
        encoder.setTexture(source.dst, index: 2)
        var u = AdvectUniforms(texelSize: texel, dt: dt, dissipation: dissipation)
        encoder.setBytes(&u, length: MemoryLayout<AdvectUniforms>.stride, index: 0)
        dispatch(encoder)
        encoder.endEncoding()
        source.swap()
    }

    private func computeDivergence(_ commandBuffer: MTLCommandBuffer, texel: SIMD2<Float>) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(divergencePipeline)
        encoder.setTexture(velocity.src, index: 0)
        encoder.setTexture(divergenceTex, index: 1)
        var u = SimpleUniforms(texelSize: texel)
        encoder.setBytes(&u, length: MemoryLayout<SimpleUniforms>.stride, index: 0)
        dispatch(encoder)
        encoder.endEncoding()
    }

    private func solvePressure(_ commandBuffer: MTLCommandBuffer, texel: SIMD2<Float>) {
        var u = SimpleUniforms(texelSize: texel)
        for _ in 0..<pressureIterations {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(jacobiPipeline)
            encoder.setTexture(pressure.src, index: 0)
            encoder.setTexture(divergenceTex, index: 1)
            encoder.setTexture(pressure.dst, index: 2)
            encoder.setBytes(&u, length: MemoryLayout<SimpleUniforms>.stride, index: 0)
            dispatch(encoder)
            encoder.endEncoding()
            pressure.swap()
        }
    }

    private func subtractGradient(_ commandBuffer: MTLCommandBuffer, texel: SIMD2<Float>) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(gradientPipeline)
        encoder.setTexture(pressure.src, index: 0)
        encoder.setTexture(velocity.src, index: 1)
        encoder.setTexture(velocity.dst, index: 2)
        var u = SimpleUniforms(texelSize: texel)
        encoder.setBytes(&u, length: MemoryLayout<SimpleUniforms>.stride, index: 0)
        dispatch(encoder)
        encoder.endEncoding()
        velocity.swap()
    }

    // MARK: Audio -> forces

    private func applyAudioForces(_ commandBuffer: MTLCommandBuffer,
                                  features: AudioAnalyzer.Features, dt: Float) {
        phase += dt * (0.25 + features.mid * 1.5)
        if beatCooldown > 0 { beatCooldown -= dt }

        let aspect = Float(simWidth) / Float(simHeight)

        // Three orbiting emitters inject swirling colored dye + tangential force.
        let emitterCount = 3
        for i in 0..<emitterCount {
            let base = phase + Float(i) * (2.0 * .pi / Float(emitterCount))
            let radius: Float = 0.30
            let center = SIMD2<Float>(0.5, 0.5)
            let point = center + SIMD2<Float>(cos(base) * radius / aspect, sin(base) * radius)

            // Tangential direction for a swirl.
            let tangent = SIMD2<Float>(-sin(base), cos(base))
            let strength = (40.0 + features.bass * 700.0) * (0.4 + features.level)
            let force = tangent * strength

            splat(commandBuffer, target: velocity, point: point,
                  radius: 0.0008, value: SIMD4<Float>(force.x, force.y, 0, 0), aspect: aspect)

            let color = spectrumColor(hueBase: base, brightness: 0.05 + features.treble * 0.9 + features.level * 0.3)
            splat(commandBuffer, target: dye, point: point,
                  radius: 0.0010, value: SIMD4<Float>(color, 1), aspect: aspect)
        }

        // On a beat, fire a bright radial burst from the center.
        if features.beat > 0.0 && beatCooldown <= 0 {
            beatCooldown = 0.12
            let center = SIMD2<Float>(0.5, 0.5)
            let burstColor = spectrumColor(hueBase: phase * 2.0, brightness: 0.6 + features.beat)
            splat(commandBuffer, target: dye, point: center,
                  radius: 0.02, value: SIMD4<Float>(burstColor * (1 + features.beat), 1), aspect: aspect)

            // Outward kick in several directions.
            let rays = 8
            for r in 0..<rays {
                let a = Float(r) * (2.0 * .pi / Float(rays))
                let dir = SIMD2<Float>(cos(a), sin(a))
                let p = center + dir * 0.04
                let f = dir * (2500.0 * features.beat)
                splat(commandBuffer, target: velocity, point: p,
                      radius: 0.004, value: SIMD4<Float>(f.x, f.y, 0, 0), aspect: aspect)
            }
        }
    }

    private func splat(_ commandBuffer: MTLCommandBuffer, target: PingPong,
                       point: SIMD2<Float>, radius: Float, value: SIMD4<Float>, aspect: Float) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(splatPipeline)
        encoder.setTexture(target.src, index: 0)
        encoder.setTexture(target.dst, index: 1)
        var u = SplatUniforms(
            texelSize: SIMD2<Float>(1.0 / Float(simWidth), 1.0 / Float(simHeight)),
            point: point, radius: radius, aspect: aspect, value: value)
        encoder.setBytes(&u, length: MemoryLayout<SplatUniforms>.stride, index: 0)
        dispatch(encoder)
        encoder.endEncoding()
        target.swap()
    }

    /// Smooth rainbow color from a hue angle.
    private func spectrumColor(hueBase: Float, brightness: Float) -> SIMD3<Float> {
        let r = 0.5 + 0.5 * cos(hueBase)
        let g = 0.5 + 0.5 * cos(hueBase + 2.094)
        let b = 0.5 + 0.5 * cos(hueBase + 4.188)
        return SIMD3<Float>(r, g, b) * max(brightness, 0)
    }

    // MARK: Display

    private func renderDye(_ commandBuffer: MTLCommandBuffer, passDescriptor: MTLRenderPassDescriptor) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        encoder.setRenderPipelineState(displayPipeline)
        encoder.setFragmentTexture(dye.src, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Dispatch helper

    private func dispatch(_ encoder: MTLComputeCommandEncoder) {
        let w = 16, h = 16
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(
            width: (simWidth + w - 1) / w,
            height: (simHeight + h - 1) / h,
            depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }
}
