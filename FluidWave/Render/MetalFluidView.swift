import SwiftUI
import MetalKit

/// SwiftUI wrapper around an `MTKView` that is driven by `FluidRenderer`.
struct MetalFluidView: NSViewRepresentable {
    let analyzer: AudioAnalyzer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let renderer = FluidRenderer(mtkView: view, analyzer: analyzer) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator {
        var renderer: FluidRenderer?
    }
}
