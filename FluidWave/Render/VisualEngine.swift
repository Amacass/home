import Foundation
import Metal
import MetalKit
import simd

/// Owns the roster of visual scenes and decides WHEN to switch between them:
/// on track changes, on large tempo shifts, or after a scene has been on
/// screen long enough (so an all-day ambient session never goes stale).
/// Scenes render into offscreen targets and are crossfaded onto the drawable.
final class VisualEngine: NSObject, ObservableObject, MTKViewDelegate {

    @Published private(set) var sceneName: String = ""
    @Published private(set) var bpmText: String = "—"

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let analyzer: AudioAnalyzer

    private var scenes: [VisualScene]
    private var activeIndex = 0
    private var incomingIndex: Int?
    private var transition: Float = 0
    private let transitionDuration: Float = 2.0

    private let texA: MTLTexture
    private let texB: MTLTexture
    private let compositePipeline: MTLRenderPipelineState

    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var time: Float = 0
    private var sceneStartTime: Float = 0
    private var bpmAtSceneStart: Float = 0
    private var manualNext = false
    private var lastPublishedBPM = -1

    // Switching policy (seconds).
    private let minAgeForTrackChangeSwitch: Float = 10
    private let minAgeForTempoSwitch: Float = 30
    private let maxSceneAge: Float = 300

    init?(analyzer: AudioAnalyzer) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.analyzer = analyzer

        // Offscreen scene targets (fixed internal resolution).
        let width = 1280
        let height = 720
        func makeTarget() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let a = makeTarget(), let b = makeTarget() else { return nil }
        self.texA = a
        self.texB = b

        // Crossfade pipeline targeting the drawable (bgra8, set by the view).
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "compositeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "compositeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let composite = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        self.compositePipeline = composite

        // Scene roster. Add new scenes here — switching and UI come for free.
        var roster: [VisualScene] = []
        if let fluid = FluidScene(device: device, library: library) { roster.append(fluid) }
        if let particles = ParticleScene(device: device, library: library,
                                         width: width, height: height) { roster.append(particles) }
        if let wave = WaveScene(device: device, library: library) { roster.append(wave) }
        if let stars = StarScene(device: device, library: library) { roster.append(stars) }
        if let rings = RingsScene(device: device, library: library) { roster.append(rings) }
        guard !roster.isEmpty else { return nil }
        self.scenes = roster

        super.init()
        sceneName = roster[0].name
    }

    /// Manually advance to the next scene (UI button).
    func requestNextScene() {
        manualNext = true
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var dt = Float(now - lastTime)
        lastTime = now
        dt = min(max(dt, 1.0 / 240.0), 1.0 / 30.0)
        time += dt

        let features = analyzer.currentFeatures()
        updateDirector(features)

        guard let commandBuffer = queue.makeCommandBuffer() else { return }

        scenes[activeIndex].render(commandBuffer: commandBuffer, target: texA,
                                   features: features, dt: dt, time: time)

        var mixT: Float = 0
        if let incoming = incomingIndex {
            scenes[incoming].render(commandBuffer: commandBuffer, target: texB,
                                    features: features, dt: dt, time: time)
            transition += dt / transitionDuration
            let t = min(transition, 1)
            mixT = t * t * (3 - 2 * t)
            if transition >= 1 {
                activeIndex = incoming
                incomingIndex = nil
                transition = 0
                sceneStartTime = time
                bpmAtSceneStart = features.bpm
                sceneName = scenes[activeIndex].name
            }
        }

        if let drawable = view.currentDrawable,
           let passDescriptor = view.currentRenderPassDescriptor,
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(texA, index: 0)
            encoder.setFragmentTexture(texB, index: 1)
            var m = mixT
            encoder.setFragmentBytes(&m, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()

        publishBPM(features.bpm)
    }

    // MARK: Director (when to switch scenes)

    private func updateDirector(_ features: AudioAnalyzer.Features) {
        guard incomingIndex == nil, scenes.count > 1 else { return }
        let age = time - sceneStartTime

        // Late-arriving tempo estimate becomes this scene's reference.
        if features.bpm > 0 && bpmAtSceneStart == 0 {
            bpmAtSceneStart = features.bpm
        }

        var shouldSwitch = false
        if manualNext {
            shouldSwitch = true
        } else if features.trackChange && age > minAgeForTrackChangeSwitch {
            // 曲の切り替わり
            shouldSwitch = true
        } else if features.bpm > 0, bpmAtSceneStart > 0,
                  abs(features.bpm - bpmAtSceneStart) > 20,
                  age > minAgeForTempoSwitch {
            // 同じ曲/ミックス内でも、テンポが大きく動いたら表情を変える
            shouldSwitch = true
        } else if age > maxSceneAge {
            // 一日中つけっぱなしでも飽きないよう、定期的にローテーション
            shouldSwitch = true
        }

        guard shouldSwitch else { return }
        manualNext = false

        // Pick a random scene other than the active one.
        var next = Int.random(in: 0..<(scenes.count - 1))
        if next >= activeIndex { next += 1 }
        incomingIndex = next
        transition = 0
    }

    private func publishBPM(_ bpm: Float) {
        let value = bpm > 0 ? Int(bpm.rounded()) : 0
        if value != lastPublishedBPM {
            lastPublishedBPM = value
            bpmText = value > 0 ? "\(value) BPM" : "—"
        }
    }
}
