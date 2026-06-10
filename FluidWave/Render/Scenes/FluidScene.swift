import Foundation
import Metal
import simd

/// GPU fluid solver (stable fluids / Stam 1999) driven by audio features,
/// with vorticity confinement (Fedkiw et al. 2001) for crisp neon strokes.
final class FluidScene: VisualScene {

    let name = "ネオン・フルイド"

    // MARK: Uniform layouts (mirror the structs in Fluid.metal)

    private struct SimpleUniforms {
        var texelSize: SIMD2<Float>
    }

    private struct AdvectUniforms {
        var texelSize: SIMD2<Float>
        var dt: Float
        var dissipation: Float
    }

    private struct VorticityUniforms {
        var texelSize: SIMD2<Float>
        var dt: Float
        var strength: Float
    }

    private struct SplatUniforms {
        var texelSize: SIMD2<Float>
        var point: SIMD2<Float>
        var radius: Float
        var aspect: Float
        var value: SIMD4<Float>
    }

    // MARK: Configuration

    /// Simulation grid resolution (16:9). Lower this if you want more FPS.
    private let simWidth: Int
    private let simHeight: Int
    private let pressureIterations: Int

    // MARK: Metal objects

    private let device: MTLDevice

    private let advectPipeline: MTLComputePipelineState
    private let divergencePipeline: MTLComputePipelineState
    private let jacobiPipeline: MTLComputePipelineState
    private let gradientPipeline: MTLComputePipelineState
    private let splatPipeline: MTLComputePipelineState
    private let curlPipeline: MTLComputePipelineState
    private let vorticityPipeline: MTLComputePipelineState
    private let displayPipeline: MTLRenderPipelineState

    private let velocity: PingPongTexture
    private let dye: PingPongTexture
    private let pressure: PingPongTexture
    private let divergenceTex: MTLTexture
    private let curlTex: MTLTexture

    // MARK: Animation state

    private var phase: Float = 0
    private var beatCooldown: Float = 0

    // MARK: Init

    init?(device: MTLDevice, library: MTLLibrary) {
        self.device = device

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
              let splat = computePipeline("splat"),
              let curl = computePipeline("curl"),
              let vorticity = computePipeline("vorticity") else {
            return nil
        }
        self.advectPipeline = advect
        self.divergencePipeline = divergence
        self.jacobiPipeline = jacobi
        self.gradientPipeline = gradient
        self.splatPipeline = splat
        self.curlPipeline = curl
        self.vorticityPipeline = vorticity

        // Display render pipeline (renders into the offscreen scene target).
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "displayFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        guard let display = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.displayPipeline = display

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
              let div = makeTexture(.r16Float), let crl = makeTexture(.r16Float) else {
            return nil
        }
        self.velocity = PingPongTexture(v0, v1)
        self.dye = PingPongTexture(d0, d1)
        self.pressure = PingPongTexture(p0, p1)
        self.divergenceTex = div
        self.curlTex = crl
    }

    // MARK: VisualScene

    func render(commandBuffer: MTLCommandBuffer, target: MTLTexture,
                features: AudioAnalyzer.Features, dt: Float, time: Float) {
        applyAudioForces(commandBuffer, features: features, dt: dt)
        step(commandBuffer, dt: dt, level: features.level)

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store
        renderDye(commandBuffer, passDescriptor: passDescriptor)
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

        // Vorticity confinement keeps swirls crisp (paint-stroke look) instead
        // of letting numerical diffusion smear everything together.
        applyVorticity(commandBuffer, texel: texel, dt: dt, strength: 30.0)

        // Projection: divergence -> pressure solve -> subtract gradient.
        computeDivergence(commandBuffer, texel: texel)
        solvePressure(commandBuffer, texel: texel)
        subtractGradient(commandBuffer, texel: texel)

        // Advect dye by the (now divergence-free) velocity field.
        runAdvect(commandBuffer, source: dye, velocity: velocity.src,
                  texel: texel, dt: dt, dissipation: dyeDissipation)
    }

    private func runAdvect(_ commandBuffer: MTLCommandBuffer, source: PingPongTexture,
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

    private func applyVorticity(_ commandBuffer: MTLCommandBuffer, texel: SIMD2<Float>,
                                dt: Float, strength: Float) {
        guard let curlEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
        curlEncoder.setComputePipelineState(curlPipeline)
        curlEncoder.setTexture(velocity.src, index: 0)
        curlEncoder.setTexture(curlTex, index: 1)
        var su = SimpleUniforms(texelSize: texel)
        curlEncoder.setBytes(&su, length: MemoryLayout<SimpleUniforms>.stride, index: 0)
        dispatch(curlEncoder)
        curlEncoder.endEncoding()

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(vorticityPipeline)
        encoder.setTexture(velocity.src, index: 0)
        encoder.setTexture(curlTex, index: 1)
        encoder.setTexture(velocity.dst, index: 2)
        var vu = VorticityUniforms(texelSize: texel, dt: dt, strength: strength)
        encoder.setBytes(&vu, length: MemoryLayout<VorticityUniforms>.stride, index: 0)
        dispatch(encoder)
        encoder.endEncoding()
        velocity.swap()
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

    /// Audio -> visual mapping, grounded in perception research:
    /// - Pitch -> elevation (Eitan & Granot 2006): bass paints low on screen,
    ///   treble high, so the layout mirrors how we hear register.
    /// - Loudness -> force/brightness via Stevens' power law (already applied
    ///   in AudioAnalyzer), so intensity tracks PERCEIVED volume.
    /// - Spectral centroid -> motion tempo (timbral brightness, Schubert &
    ///   Wolfe 2006): bright timbres dart, dark timbres glide.
    /// - Onsets (spectral flux) -> bursts at the dominant register's stroke.
    /// Each register injects exactly ONE paint channel (x=bass red, y=mid
    /// green, z=treble blue); the display shader keeps them from mixing.
    private func applyAudioForces(_ commandBuffer: MTLCommandBuffer,
                                  features: AudioAnalyzer.Features, dt: Float) {
        let level = features.level
        let bass = features.bass
        let mid = features.mid
        let treble = features.treble

        // Motion only advances while music plays; silence freezes the strokes
        // and the field just dissipates to black.
        phase += dt * (0.8 + features.centroid * 2.6) * level
        if beatCooldown > 0 { beatCooldown -= dt }
        guard level > 0.02 else { return }

        let aspect = Float(simWidth) / Float(simHeight)

        // --- Bass: a wide, slow red stroke sweeping low across the screen ---
        if bass > 0.04 {
            let pb = phase * 0.5
            let point = SIMD2<Float>(0.5 + 0.34 * sin(pb), 0.26 + 0.05 * sin(2 * pb))
            var tangent = SIMD2<Float>(0.34 * cos(pb), 0.10 * cos(2 * pb))
            tangent = normalize(tangent + SIMD2<Float>(1e-5, 0))
            let force = tangent * (1000.0 * bass * level)
            splat(commandBuffer, target: velocity, point: point,
                  radius: 0.0016, value: SIMD4<Float>(force.x, force.y, 0, 0), aspect: aspect)
            splat(commandBuffer, target: dye, point: point,
                  radius: 0.0014, value: SIMD4<Float>(bass * level * 1.6, 0, 0, 0), aspect: aspect)
        }

        // --- Mids / melody: a green orbit through the middle register ---
        if mid > 0.04 {
            let pm = phase
            let center = SIMD2<Float>(0.5, 0.50)
            let point = center + SIMD2<Float>(cos(pm) * 0.20 / aspect, sin(pm) * 0.16)
            let tangent = normalize(SIMD2<Float>(-sin(pm), cos(pm)))
            let force = tangent * (750.0 * mid * level)
            splat(commandBuffer, target: velocity, point: point,
                  radius: 0.0008, value: SIMD4<Float>(force.x, force.y, 0, 0), aspect: aspect)
            splat(commandBuffer, target: dye, point: point,
                  radius: 0.0008, value: SIMD4<Float>(0, mid * level * 1.5, 0, 0), aspect: aspect)
        }

        // --- Treble: thin, fast blue filaments along the top ---
        if treble > 0.06 {
            let pt = phase * 2.4
            let point = SIMD2<Float>(0.5 + 0.36 * sin(pt), 0.74 + 0.04 * sin(3 * pt))
            var tangent = SIMD2<Float>(0.36 * cos(pt), 0.12 * cos(3 * pt))
            tangent = normalize(tangent + SIMD2<Float>(1e-5, 0))
            let force = tangent * (650.0 * treble * level)
            splat(commandBuffer, target: velocity, point: point,
                  radius: 0.0004, value: SIMD4<Float>(force.x, force.y, 0, 0), aspect: aspect)
            splat(commandBuffer, target: dye, point: point,
                  radius: 0.0004, value: SIMD4<Float>(0, 0, treble * level * 1.4, 0), aspect: aspect)
        }

        // --- Onset: burst from the dominant register, in ITS paint ---
        if features.beat > 0.0 && beatCooldown <= 0 {
            beatCooldown = 0.10
            let beat = features.beat

            let origin: SIMD2<Float>
            let paint: SIMD4<Float>
            if bass >= mid && bass >= treble {
                origin = SIMD2<Float>(0.5 + 0.34 * sin(phase * 0.5), 0.26)
                paint = SIMD4<Float>(1.8 * (0.5 + beat), 0, 0, 0)
            } else if mid >= treble {
                origin = SIMD2<Float>(0.5, 0.50)
                paint = SIMD4<Float>(0, 1.8 * (0.5 + beat), 0, 0)
            } else {
                origin = SIMD2<Float>(0.5 + 0.36 * sin(phase * 2.4), 0.74)
                paint = SIMD4<Float>(0, 0, 1.8 * (0.5 + beat), 0)
            }

            splat(commandBuffer, target: dye, point: origin,
                  radius: 0.012, value: paint, aspect: aspect)

            let rays = 10
            for r in 0..<rays {
                let a = Float(r) * (2.0 * .pi / Float(rays)) + phase
                let dir = SIMD2<Float>(cos(a), sin(a))
                let p = origin + dir * 0.04
                let f = dir * (2400.0 * beat * level)
                splat(commandBuffer, target: velocity, point: p,
                      radius: 0.003, value: SIMD4<Float>(f.x, f.y, 0, 0), aspect: aspect)
            }
        }
    }

    private func splat(_ commandBuffer: MTLCommandBuffer, target: PingPongTexture,
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
