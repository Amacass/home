import Metal

/// A self-contained audio-reactive visual. Each scene renders a complete
/// frame into an offscreen target texture; `VisualEngine` owns the scene
/// roster and crossfades between scenes on musical transitions.
///
/// To add a new visual, conform to this protocol and register the scene in
/// `VisualEngine.init` — switching, transitions and UI come for free.
protocol VisualScene: AnyObject {
    var name: String { get }
    func render(commandBuffer: MTLCommandBuffer,
                target: MTLTexture,
                features: AudioAnalyzer.Features,
                dt: Float,
                time: Float)
}

/// Two textures that swap roles each pass (simulation ping-pong).
final class PingPongTexture {
    var src: MTLTexture
    var dst: MTLTexture
    init(_ a: MTLTexture, _ b: MTLTexture) { src = a; dst = b }
    func swap() { Swift.swap(&src, &dst) }
}
