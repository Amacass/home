import SwiftUI
import MetalKit

/// SwiftUI wrapper around an `MTKView` driven by `VisualEngine`.
struct MetalFluidView: NSViewRepresentable {
    let engine: VisualEngine

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = engine.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = engine
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
