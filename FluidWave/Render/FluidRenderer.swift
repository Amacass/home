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
        step(commandBuffer, dt: dt, level: features.level)

        if let drawable = view.currentDrawable,
           let passDescriptor = view.currentRenderPassDescriptor {
            renderDye(commandBuffer, passDescriptor: passDescriptor)
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    // MARK: Simulation step

    private func step(_ commandBuffer: MTLCommandBuffer, dt: Float, level: Float) {
        let texel = SIMD2<Float>(1.0 / Float(simWidth), 1.0 / Float(simHeight))

        // Persistence scales with the music: loud -> flowing trails, silent ->
        // both velocity and dye decay within ~1s so the screen calms and darkens.
        let velocityDissipation = 0.965 + 0.033 * level
        let dyeDissipation = 0.94 + 0.045 * level

        // Advect velocity by itself.
        runAdvect(commandBuffer, source: velocity, velocity: velocity.src,
                  texel: texel, dt: dt, dissipation: velocityDissipation)

        // Projection: divergence -> pressure solve -> subtract gradient.
        computeDivergence(commandBuffer, texel: texel)
        solvePressure(commandBuffer, texel: texel)
        subtractGradient(commandBuffer, texel: texel)

        // Advect dye by the (now divergence-free) velocity field.
        runAdvect(commandBuffer, source: dye, velocity: velocity.src,
                  texel: texel, dt: dt, dissipation: dyeDissipation)
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
        let level = features.level
        let bass = features.bass
        let mid = features.mid
        let treble = features.treble

        // Motion only advances while the music plays. At silence `phase` freezes
        // and, with no new forces injected, the field simply dissipates.
        phase += dt * (1.0 + mid * 4.0 + bass * 2.0) * level
        if beatCooldown > 0 { beatCooldown -= dt }

        // Effectively silent -> inject nothing, let the fluid calm down.
        guard level > 0.02 else { return }

        let aspect = Float(simWidth) / Float(simHeight)
        let center = SIMD2<Float>(0.5, 0.5)

        // Color reflects the live spectral balance, renormalized to full neon
        // saturation so distinct frequencies read as distinct glowing hues.
        let spectralColor = neonColor(bass: bass, mid: mid, treble: treble)

        // --- Mids / melody: orbiting light emitters that drive a swirl ---
        let emitterCount = 3
        for i in 0..<emitterCount {
            let base = phase + Float(i) * (2.0 * .pi / Float(emitterCount))
            let radius: Float = 0.22 + bass * 0.12
            let point = center + SIMD2<Float>(cos(base) * radius / aspect, sin(base) * radius)
            let tangent = SIMD2<Float>(-sin(base), cos(base))

            let force = tangent * (mid * 600.0 + bass * 350.0) * level
            splat(commandBuffer, target: velocity, point: point,
                  radius: 0.0007, value: SIMD4<Float>(force.x, force.y, 0, 0), aspect: aspect)

            let brightness = (0.15 + mid * 1.3) * level
            splat(commandBuffer, target: dye, point: point,
                  radius: 0.0009, value: SIMD4<Float>(spectralColor * brightness, 1), aspect: aspect)
        }

        // --- Highs / treble: fast shimmering sparks around the rim ---
        if treble > 0.25 {
            let sparkColor = neonColor(bass: 0, mid: 0.15, treble: 1.0)
            for s in 0..<3 {
                let a = phase * 5.0 + Float(s) * 2.4
                let rr: Float = 0.30 + 0.12 * sin(phase * 3.0 + Float(s))
                let p = center + SIMD2<Float>(cos(a) * rr / aspect, sin(a) * rr)
                splat(commandBuffer, target: dye, point: p,
                      radius: 0.00022, value: SIMD4<Float>(sparkColor * treble * 1.2, 1), aspect: aspect)
            }
        }

        // --- Beat / bass hit: a bright central pulse + radial shockwave ---
        if features.beat > 0.0 && beatCooldown <= 0 {
            beatCooldown = 0.11
            let beat = features.beat
            let burstColor = neonColor(bass: 1.0, mid: mid, treble: treble * 0.5)
            splat(commandBuffer, target: dye, point: center,
                  radius: 0.025, value: SIMD4<Float>(burstColor * (0.7 + beat), 1), aspect: aspect)

            let rays = 10
            for r in 0..<rays {
                let a = Float(r) * (2.0 * .pi / Float(rays)) + phase
                let dir = SIMD2<Float>(cos(a), sin(a))
                let p = center + dir * 0.05
                let f = dir * (2200.0 * beat * (0.5 + bass))
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

    /// Maps the spectral balance to a vivid neon color, renormalized to full
    /// saturation so colors stay punchy instead of washing out to grey/white.
    private func neonColor(bass: Float, mid: Float, treble: Float) -> SIMD3<Float> {
        let bassColor   = SIMD3<Float>(1.00, 0.15, 0.55) // hot magenta
        let midColor    = SIMD3<Float>(0.20, 1.00, 0.45) // electric green
        let trebleColor = SIMD3<Float>(0.30, 0.55, 1.00) // electric blue
        var c = bassColor * bass + midColor * mid + trebleColor * treble
        let m = max(c.x, max(c.y, c.z))
        if m < 1e-4 { return SIMD3<Float>(repeating: 0) }
        c = c / m // full neon saturation
        return c
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
