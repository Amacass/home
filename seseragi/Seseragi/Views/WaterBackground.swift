import SwiftUI

/// 清流をイメージした背景。
/// 深い青緑のグラデーションの上を、半透明の波が静かに流れる。
struct WaterBackground: View {

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.01, green: 0.05, blue: 0.10),
                    Color(red: 0.01, green: 0.14, blue: 0.21),
                    Color(red: 0.02, green: 0.24, blue: 0.27),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    drawWave(in: &context, size: size, time: time,
                             amplitude: 14, wavelength: 1.1, speed: 0.10,
                             baseline: 0.30, opacity: 0.05)
                    drawWave(in: &context, size: size, time: time,
                             amplitude: 20, wavelength: 0.8, speed: -0.07,
                             baseline: 0.55, opacity: 0.06)
                    drawWave(in: &context, size: size, time: time,
                             amplitude: 26, wavelength: 0.6, speed: 0.05,
                             baseline: 0.80, opacity: 0.07)
                }
            }
        }
        .ignoresSafeArea()
    }

    /// baseline（0〜1）の高さから画面下端までを塗る、ゆっくり流れる波を1本描く
    private func drawWave(in context: inout GraphicsContext, size: CGSize, time: TimeInterval,
                          amplitude: CGFloat, wavelength: CGFloat, speed: Double,
                          baseline: CGFloat, opacity: CGFloat) {
        let baseY = size.height * baseline
        let phase = CGFloat(time * speed) * 2 * .pi

        var path = Path()
        path.move(to: CGPoint(x: 0, y: baseY))
        let step: CGFloat = 6
        var x: CGFloat = 0
        while x <= size.width + step {
            let y = baseY + amplitude * sin((x / size.width) * wavelength * 2 * .pi + phase)
            path.addLine(to: CGPoint(x: x, y: y))
            x += step
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()

        context.fill(path, with: .color(.white.opacity(opacity)))
    }
}

#Preview {
    WaterBackground()
}
