import SwiftUI

// The moving parts of the waiting screens. People watch a make for minutes while the GPU is busy
// with the 3D engine, so everything here is cheap: symbol effects, one-off animations, and
// sweeps that rest between crossings (SwiftUI only draws while something moves). With Reduce
// Motion on, the sweeps and glides stay still.

/// A progress bar whose fill glides between updates (they come about once a second) and, while
/// `working`, has a soft light crossing it now and then, so a bar that moves 0.2% a second
/// still looks alive. Finishing fills it the rest of the way; failing drops it at once.
struct GlidingBar: ProgressViewStyle {
    var working: Bool

    func makeBody(configuration: Configuration) -> some View {
        Bar(fraction: min(1, max(0, configuration.fractionCompleted ?? 0)), working: working)
    }

    private struct Bar: View {
        let fraction: Double
        let working: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint)
                        .overlay { if working && !reduceMotion { LightSweep() } }
                        .clipShape(Capsule())
                        .frame(width: g.size.width * fraction)
                        .opacity(fraction > 0 ? 1 : 0)
                }
            }
            .frame(height: 6)
            .animation(reduceMotion ? nil : working ? .linear(duration: 1) : fraction == 1 ? .easeOut(duration: 0.5) : nil,
                       value: fraction)
        }
    }
}

/// A soft band of light that crosses its view now and then: the bar's sheen, the picture's scan.
/// It rests between crossings, so it costs a moment of drawing every few seconds rather than
/// every frame of a ten-minute job.
struct LightSweep: View {
    var vertical = false
    var crossing = 1.4
    var rest = 2.0
    var strength = 0.45
    @State private var across = false

    var body: some View {
        GeometryReader { g in
            let length = vertical ? g.size.height : g.size.width
            let band = max(24, length * 0.4)
            LinearGradient(colors: [.clear, .white.opacity(strength), .clear],
                           startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
                .frame(width: vertical ? nil : band, height: vertical ? band : nil)
                .offset(x: vertical ? 0 : across ? length : -band, y: vertical ? across ? length : -band : 0)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(rest))
                withAnimation(.easeInOut(duration: crossing)) { across = true }
                try? await Task.sleep(for: .seconds(crossing))
                across = false  // back to the start, out of sight, without animating
            }
        }
    }
}
